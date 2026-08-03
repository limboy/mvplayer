import AppKit
import Combine
import Foundation
import MediaPlayer

@MainActor
final class AppModel: ObservableObject {
    let playerState = PlayerState()
    let folderLibrary: FolderLibrary
    let playbackQueue: PlaybackQueue
    let progressStore: PlaybackProgressStore

    @Published private(set) var engine: MPVPlayerEngine?
    @Published private(set) var videoView: MVVideoView?
    @Published private(set) var startupError: String?
    @Published private(set) var progressRevision = 0

    private var queueDirectory: URL?
    private var cancellables = Set<AnyCancellable>()

    /// Held while a video is playing, to keep the display awake. Nil whenever
    /// nothing is playing, which is also how the state is read.
    private var playbackActivity: NSObjectProtocol?

    init(
        folderLibrary: FolderLibrary = FolderLibrary(),
        playbackQueue: PlaybackQueue = PlaybackQueue(),
        progressStore: PlaybackProgressStore = PlaybackProgressStore()
    ) {
        self.folderLibrary = folderLibrary
        self.playbackQueue = playbackQueue
        self.progressStore = progressStore

        folderLibrary.onVisibleVideosChanged = { [weak self] directory, videos in
            guard let self else { return }
            guard let directory else {
                self.closeVideo()
                return
            }
            guard directory == self.queueDirectory else { return }
            self.playbackQueue.updateVideos(videos)
        }
        observePlayerState()
        configureRemoteCommands()
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
            videoView = MVVideoView(engine: engine)
        } catch {
            startupError = error.localizedDescription
            engine = nil
            videoView = nil
        }
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
        folderLibrary.selectVideo(url)
        playbackQueue.select(url, from: videos)
        loadVideo(url)
    }

    func playNext() {
        guard let next = playbackQueue.next() else { return }
        saveCurrentProgress()
        folderLibrary.selectVideo(next)
        loadVideo(next)
    }

    func playPrevious() {
        guard let previous = playbackQueue.previous() else { return }
        saveCurrentProgress()
        folderLibrary.selectVideo(previous)
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
        folderLibrary.selectedVideo = nil
        playbackQueue.clear()
        engine?.stop()
        videoView?.setVideoRenderingEnabled(false)
        playerState.reset()
        updateNowPlaying()
    }

    func playbackProgress(for url: URL) -> PlaybackProgress? {
        progressStore.progress(for: url)
    }

    private func advanceAfterEnd() {
        if let currentURL = playerState.currentURL {
            progressStore.markFinished(url: currentURL, duration: playerState.duration)
            progressRevision &+= 1
        }
        guard let next = playbackQueue.next(automatic: true) else { return }
        saveCurrentProgress()
        folderLibrary.selectVideo(next)
        loadVideo(next)
    }

    private func loadVideo(_ url: URL) {
        videoView?.setVideoRenderingEnabled(true)
        engine?.load(
            url,
            startAt: resumePosition(for: url),
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
        progressRevision &+= 1
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [5]
        center.skipBackwardCommand.preferredIntervals = [5]

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.engine?.setPaused(false) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.engine?.setPaused(true) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.playPrevious() }
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seek(by: 5) }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.seek(by: -5) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.engine?.seek(to: event.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        let commandCenter = MPRemoteCommandCenter.shared()
        guard let url = playerState.currentURL else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            commandCenter.nextTrackCommand.isEnabled = false
            commandCenter.previousTrackCommand.isEnabled = false
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: url.deletingPathExtension().lastPathComponent,
            MPMediaItemPropertyAssetURL: url,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playerState.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playerState.isPaused ? 0 : 1
        ]
        if playerState.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = playerState.duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playerState.isPaused ? .paused : .playing
        commandCenter.nextTrackCommand.isEnabled = playbackQueue.videos.count > 1
        commandCenter.previousTrackCommand.isEnabled = playbackQueue.videos.count > 1
    }
}
