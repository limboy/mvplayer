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
    private var pendingResumeURL: URL?
    private var pendingResumeTime: Double?
    private var cancellables = Set<AnyCancellable>()

    init(
        folderLibrary: FolderLibrary = FolderLibrary(),
        playbackQueue: PlaybackQueue = PlaybackQueue(),
        progressStore: PlaybackProgressStore = PlaybackProgressStore()
    ) {
        self.folderLibrary = folderLibrary
        self.playbackQueue = playbackQueue
        self.progressStore = progressStore

        folderLibrary.onVisibleVideosChanged = { [weak self] directory, videos in
            guard let self, directory == self.queueDirectory else { return }
            self.playbackQueue.updateVideos(videos)
        }
        observePlayerState()
        configureRemoteCommands()
        retryLibMPV()
    }

    func retryLibMPV() {
        startupError = nil
        do {
            let engine = try MPVPlayerEngine(state: playerState)
            engine.onPlaybackEnded = { [weak self] in
                self?.advanceAfterEnd()
            }
            engine.onFileLoaded = { [weak self] in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    self?.applyPendingResume()
                }
            }
            self.engine = engine
            videoView = MVVideoView(engine: engine)
        } catch {
            startupError = error.localizedDescription
            engine = nil
            videoView = nil
        }
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
        pendingResumeURL = url.standardizedFileURL
        pendingResumeTime = progressStore.progress(for: url)?.position
        engine?.load(url)
        updateNowPlaying()
    }

    private func applyPendingResume() {
        guard let url = pendingResumeURL,
              url == playerState.currentURL?.standardizedFileURL,
              let time = pendingResumeTime
        else {
            pendingResumeURL = nil
            pendingResumeTime = nil
            return
        }
        guard time >= 15, playerState.duration > time + 30 else { return }
        pendingResumeURL = nil
        pendingResumeTime = nil
        engine?.seek(to: time)
    }

    private func observePlayerState() {
        playerState.$currentTime
            .combineLatest(playerState.$duration, playerState.$currentURL)
            .throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _, _, _ in
                self?.applyPendingResume()
                self?.saveCurrentProgress()
                self?.updateNowPlaying()
            }
            .store(in: &cancellables)

        playerState.$isPaused
            .sink { [weak self] _ in self?.updateNowPlaying() }
            .store(in: &cancellables)
        playerState.$duration
            .sink { [weak self] _ in self?.applyPendingResume() }
            .store(in: &cancellables)
        playerState.$volume
            .sink { [weak self] _ in self?.updateNowPlaying() }
            .store(in: &cancellables)
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
