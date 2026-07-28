import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let playerState = PlayerState()
    let folderLibrary: FolderLibrary
    let playbackQueue: PlaybackQueue

    @Published private(set) var engine: MPVPlayerEngine?
    @Published private(set) var videoView: MVVideoView?
    @Published private(set) var startupError: String?

    private var queueDirectory: URL?

    init(
        folderLibrary: FolderLibrary = FolderLibrary(),
        playbackQueue: PlaybackQueue = PlaybackQueue()
    ) {
        self.folderLibrary = folderLibrary
        self.playbackQueue = playbackQueue

        folderLibrary.onVisibleVideosChanged = { [weak self] directory, videos in
            guard let self, directory == self.queueDirectory else { return }
            self.playbackQueue.updateVideos(videos)
        }
        retryLibMPV()
    }

    func retryLibMPV() {
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

    func play(_ url: URL, from videos: [URL], directory: URL?) {
        guard let engine else { return }
        queueDirectory = directory
        folderLibrary.selectVideo(url)
        playbackQueue.select(url, from: videos)
        engine.load(url)
    }

    func playNext() {
        guard let next = playbackQueue.next() else { return }
        folderLibrary.selectVideo(next)
        engine?.load(next)
    }

    func playPrevious() {
        guard let previous = playbackQueue.previous() else { return }
        folderLibrary.selectVideo(previous)
        engine?.load(previous)
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

    private func advanceAfterEnd() {
        guard let next = playbackQueue.next(automatic: true) else { return }
        folderLibrary.selectVideo(next)
        engine?.load(next)
    }
}
