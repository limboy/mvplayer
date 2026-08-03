import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let playerState = PlayerState()

    /// The browser's library, or nil in a window that was opened on a single
    /// file and has no browser of its own.
    let folderLibrary: FolderLibrary?

    let playbackQueue: PlaybackQueue
    let progressStore: PlaybackProgressStore

    @Published private(set) var engine: MPVPlayerEngine?
    @Published private(set) var videoView: MVVideoView?
    @Published private(set) var startupError: String?
    @Published private(set) var progressRevision = 0

    private var queueDirectory: URL?
    private var cancellables = Set<AnyCancellable>()

    /// A file asked for before there was anything to draw it with.
    ///
    /// mpv initializes a file's video stream against the render context as the
    /// file is opened, and the context only exists once the video view has
    /// drawn. A window that opens onto a file asks for it while the window is
    /// still being built, which is well before that: the file would play with no
    /// picture, or — having no audio to fall back on — end at once with
    /// `MPV_ERROR_NOTHING_TO_PLAY`. It waits here instead, and goes to mpv on
    /// the first draw.
    private var pendingLoad: (url: URL, startAt: Double?)?

    /// Held while a video is playing, to keep the display awake. Nil whenever
    /// nothing is playing, which is also how the state is read.
    private var playbackActivity: NSObjectProtocol?

    init(
        folderLibrary: FolderLibrary?,
        playbackQueue: PlaybackQueue = PlaybackQueue(),
        progressStore: PlaybackProgressStore = .shared
    ) {
        self.folderLibrary = folderLibrary
        self.playbackQueue = playbackQueue
        self.progressStore = progressStore

        folderLibrary?.onVisibleVideosChanged = { [weak self] directory, videos in
            guard let self else { return }
            guard let directory else {
                self.closeVideo()
                return
            }
            guard directory == self.queueDirectory else { return }
            self.playbackQueue.updateVideos(videos)
        }
        observePlayerState()
        retryLibMPV()
    }

    func retryLibMPV() {
        teardownPlayer()
        startupError = nil
        do {
            let engine = try MPVPlayerEngine(state: playerState)
            engine.onPlaybackEnded = { [weak self] in
                self?.advanceAfterEnd()
            }
            self.engine = engine
            let videoView = MVVideoView(engine: engine)
            videoView.onRendererReady = { [weak self] in
                self?.loadPendingVideo()
            }
            self.videoView = videoView
        } catch {
            startupError = error.localizedDescription
            engine = nil
            videoView = nil
        }
    }

    /// Lets go of everything the window owned, for a window that is closing.
    ///
    /// A window whose views simply disappeared would leave mpv decoding — and
    /// playing sound — behind a picture nobody can see, and would go on
    /// answering the media keys from nowhere.
    func shutdown() {
        closeVideo()
        NowPlayingCenter.shared.resign(self)
        teardownPlayer()
        cancellables.removeAll()
    }

    /// Pauses so that another window can be heard. Keeps the file and the
    /// position, so playing this window again carries on from here.
    func yieldPlayback() {
        guard playerState.hasMedia, !playerState.isPaused else { return }
        engine?.setPaused(true)
    }

    /// Releases the renderer before the engine, in that order. mpv holds an
    /// unretained pointer back to the video view for render updates, and
    /// mvp_mpv_destroy tears down the render context, so leaving either
    /// attached past this point leaves the render queue pointing at freed
    /// memory.
    private func teardownPlayer() {
        videoView?.detachRenderer()
        videoView = nil
        engine?.shutdown()
        engine = nil
    }

    func play(_ url: URL, from videos: [URL], directory: URL?) {
        guard engine != nil else { return }
        saveCurrentProgress()
        queueDirectory = directory
        folderLibrary?.selectVideo(url)
        playbackQueue.select(url, from: videos)
        loadVideo(url)
    }

    func playNext() {
        guard let next = playbackQueue.next() else { return }
        saveCurrentProgress()
        folderLibrary?.selectVideo(next)
        loadVideo(next)
    }

    func playPrevious() {
        guard let previous = playbackQueue.previous() else { return }
        saveCurrentProgress()
        folderLibrary?.selectVideo(previous)
        loadVideo(previous)
    }

    func togglePlayPause() {
        guard playerState.hasMedia else { return }
        engine?.togglePause()
    }

    func seek(by seconds: Double) {
        guard playerState.hasMedia else { return }
        engine?.seek(by: seconds)
    }

    func changeVolume(by amount: Double) {
        engine?.setVolume(playerState.volume + amount)
    }

    func closeVideo() {
        if playerState.hasMedia {
            saveCurrentProgress()
        }
        queueDirectory = nil
        pendingLoad = nil
        folderLibrary?.selectedVideo = nil
        playbackQueue.clear()
        engine?.stop()
        videoView?.setVideoRenderingEnabled(false)
        playerState.reset()
        updateNowPlaying()
    }

    func playbackProgress(for url: URL) -> PlaybackProgress? {
        progressStore.progress(for: url)
    }

    /// Whether a file has been asked for that mpv has not been given yet,
    /// because the view it would be drawn in has not drawn once.
    var isWaitingForRenderer: Bool {
        pendingLoad != nil
    }

    private func advanceAfterEnd() {
        if let currentURL = playerState.currentURL {
            progressStore.markFinished(url: currentURL, duration: playerState.duration)
        }
        guard let next = playbackQueue.next(automatic: true) else { return }
        saveCurrentProgress()
        folderLibrary?.selectVideo(next)
        loadVideo(next)
    }

    private func loadVideo(_ url: URL) {
        // Opening a file is what makes this window the one being watched, and
        // so the one the media keys and the Now Playing panel belong to.
        NowPlayingCenter.shared.activate(self)
        videoView?.setVideoRenderingEnabled(true)

        let startAt = resumePosition(for: url)
        guard videoView?.isRendererReady == true else {
            pendingLoad = (url, startAt)
            // The file is what the window is showing from this moment, even
            // though mpv has not been given it yet: the title, the row's
            // highlight and the spinner all read this.
            playerState.resetForLoad(url)
            updateNowPlaying()
            return
        }

        pendingLoad = nil
        engine?.load(url, startAt: startAt, selectsSubtitles: SubtitlePreference.isEnabled)
        updateNowPlaying()
    }

    /// Hands mpv the file that was waiting for a renderer, once there is one.
    private func loadPendingVideo() {
        guard let pendingLoad else { return }
        self.pendingLoad = nil
        engine?.load(
            pendingLoad.url,
            startAt: pendingLoad.startAt,
            selectsSubtitles: SubtitlePreference.isEnabled
        )
        updateNowPlaying()
    }

    /// Where a video should pick up, or nil to start it from the beginning.
    ///
    /// The running time comes from the stored progress rather than from the
    /// player, because the decision is made before the file is open and mpv has
    /// not reported a duration yet. The store records both together, so it
    /// already knows how far in the position was.
    private func resumePosition(for url: URL) -> Double? {
        guard let progress = progressStore.progress(for: url) else { return nil }
        // Far enough in to be worth returning to, and far enough from the end
        // that there is something left to watch.
        guard progress.position >= 15, progress.duration > progress.position + 30 else {
            return nil
        }
        return progress.position
    }

    private func observePlayerState() {
        // The store is shared by every window, so the browser's ticks and bars
        // follow a file watched in a window of its own as closely as one watched
        // here. It is the only thing that writes progress, which makes it the
        // one place worth watching for a change to it.
        progressStore.objectWillChange
            .sink { [weak self] _ in
                self?.progressRevision &+= 1
            }
            .store(in: &cancellables)

        playerState.$currentTime
            .combineLatest(playerState.$duration, playerState.$currentURL)
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _, _, _ in
                self?.saveCurrentProgress()
                self?.updateNowPlaying()
            }
            .store(in: &cancellables)

        playerState.$isPaused
            .sink { [weak self] _ in self?.updateNowPlaying() }
            .store(in: &cancellables)
        playerState.$volume
            .sink { [weak self] _ in self?.updateNowPlaying() }
            .store(in: &cancellables)

        // The published values, not the properties: @Published fires before the
        // new value is stored, so reading playerState here would see the old one.
        playerState.$isPaused
            .combineLatest(playerState.$currentURL)
            .sink { [weak self] isPaused, url in
                self?.setPlaybackKeepingDisplayAwake(url != nil && !isPaused)
            }
            .store(in: &cancellables)
    }

    /// Keeps the display awake while a video is playing, and lets it sleep
    /// again as soon as one is not.
    private func setPlaybackKeepingDisplayAwake(_ isPlaying: Bool) {
        if isPlaying, playbackActivity == nil {
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Playing video"
            )
        } else if !isPlaying, let playbackActivity {
            ProcessInfo.processInfo.endActivity(playbackActivity)
            self.playbackActivity = nil
        }
    }

    private func saveCurrentProgress() {
        guard let url = playerState.currentURL,
              playerState.currentTime >= 0
        else { return }
        progressStore.record(
            url: url,
            position: playerState.currentTime,
            duration: playerState.duration
        )
    }

    private func updateNowPlaying() {
        NowPlayingCenter.shared.update(from: self)
    }
}
