import MediaPlayer
import XCTest
@testable import MVPlayer

/// The system's Now Playing panel belongs to the process, and there is a player
/// per window. These check that the panel follows one window at a time — the one
/// that started playing most recently — rather than being fought over.
@MainActor
final class NowPlayingRoutingTests: XCTestCase {
    private var directory: URL!
    private var models: [AppModel] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerNowPlayingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for model in models {
            NowPlayingCenter.shared.resign(model)
        }
        models = []
        try? FileManager.default.removeItem(at: directory)
    }

    func testThePanelFollowsTheWindowThatStartedPlayingLast() {
        let folder = makeModel(playing: "folder.mp4")
        NowPlayingCenter.shared.activate(folder)
        XCTAssertEqual(nowPlayingTitle, "folder")

        let file = makeModel(playing: "opened-on-its-own.mkv")
        NowPlayingCenter.shared.activate(file)

        XCTAssertEqual(
            nowPlayingTitle,
            "opened-on-its-own",
            "the window that just started playing should be the one the panel shows"
        )
    }

    func testAWindowThePanelIsNotFollowingCannotOverwriteIt() {
        let folder = makeModel(playing: "folder.mp4")
        let file = makeModel(playing: "opened-on-its-own.mkv")
        NowPlayingCenter.shared.activate(file)

        folder.playerState.currentTime = 90
        NowPlayingCenter.shared.update(from: folder)

        XCTAssertEqual(nowPlayingTitle, "opened-on-its-own")
        XCTAssertEqual(
            nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double,
            0,
            "a window in the background should not report its clock to the panel"
        )
    }

    func testClosingTheFollowedWindowEmptiesThePanel() {
        let file = makeModel(playing: "opened-on-its-own.mkv")
        NowPlayingCenter.shared.activate(file)
        XCTAssertNotNil(nowPlayingInfo)

        file.shutdown()

        XCTAssertNil(nowPlayingInfo, "a window that has closed should leave nothing playing")
    }

    func testClosingABackgroundWindowLeavesThePanelAlone() {
        let folder = makeModel(playing: "folder.mp4")
        let file = makeModel(playing: "opened-on-its-own.mkv")
        NowPlayingCenter.shared.activate(file)

        folder.shutdown()

        XCTAssertEqual(
            nowPlayingTitle,
            "opened-on-its-own",
            "closing a window nobody was following should not stop what is playing"
        )
    }

    /// A window opened on one file has that file and nothing else to play, so
    /// there is nowhere for it to go when it reaches the end.
    func testAFileOpenedOnItsOwnHasAQueueOfOne() throws {
        let model = makeModel()
        try XCTSkipIf(model.engine == nil, "libmpv is not installed")
        let url = directory.appendingPathComponent("opened-on-its-own.mkv")

        model.play(url, from: [url], directory: nil)

        XCTAssertEqual(model.playbackQueue.videos, [url])
        XCTAssertNil(model.playbackQueue.next(), "there is nothing after the only file")
        XCTAssertNil(model.playbackQueue.previous())
    }

    /// The store is shared, so where a file was left off is the same answer in
    /// every window.
    func testEveryWindowRecordsIntoTheSameProgressStore() {
        let store = PlaybackProgressStore(
            storageURL: directory.appendingPathComponent("progress.json")
        )
        let folder = makeModel(progressStore: store)
        let file = makeModel(progressStore: store)
        let url = directory.appendingPathComponent("opened-on-its-own.mkv")

        file.progressStore.record(url: url, position: 120, duration: 600)

        XCTAssertEqual(folder.playbackProgress(for: url)?.position, 120)
    }

    private func makeModel(
        playing name: String? = nil,
        progressStore: PlaybackProgressStore? = nil
    ) -> AppModel {
        let model = AppModel(
            folderLibrary: nil,
            progressStore: progressStore ?? PlaybackProgressStore(
                storageURL: directory.appendingPathComponent("progress-\(UUID().uuidString).json")
            )
        )
        if let name {
            model.playerState.currentURL = directory.appendingPathComponent(name)
        }
        models.append(model)
        return model
    }

    private var nowPlayingInfo: [String: Any]? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo
    }

    private var nowPlayingTitle: String? {
        nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
    }
}
