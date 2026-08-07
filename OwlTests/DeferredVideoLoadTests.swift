import XCTest
@testable import Owl

/// A window opened on a file asks for it while the window is still being built,
/// before the video view has drawn and so before mpv has a render context. mpv
/// initializes a file's video stream against that context as the file opens, so
/// a file handed over too early plays without a picture, and a file with no
/// audio to fall back on ends at once with `MPV_ERROR_NOTHING_TO_PLAY` (-16).
@MainActor
final class DeferredVideoLoadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwlDeferredLoadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAFileAskedForBeforeTheFirstDrawWaitsForTheRenderer() throws {
        let model = try makeModel()
        let url = directory.appendingPathComponent("no-audio.mp4")

        model.play(url, from: [url], directory: nil)

        XCTAssertFalse(
            model.videoView?.isRendererReady ?? true,
            "a view that has never drawn has no render context"
        )
        XCTAssertTrue(model.isWaitingForRenderer, "the file should be held back")
    }

    /// The window still shows the file it was opened on while it waits: the
    /// spinner, the title and the row highlight all read the player's state.
    func testTheWaitingFileIsAlreadyThePlayersFile() throws {
        let model = try makeModel()
        let url = directory.appendingPathComponent("no-audio.mp4")

        model.play(url, from: [url], directory: nil)

        XCTAssertEqual(model.playerState.currentURL, url)
        XCTAssertTrue(model.playerState.isLoading)
    }

    func testTheFileGoesToMPVOnceThereIsARenderer() throws {
        let model = try makeModel()
        let url = directory.appendingPathComponent("no-audio.mp4")
        model.play(url, from: [url], directory: nil)

        // What the video view reports for itself on its first draw.
        model.videoView?.onRendererReady?()

        XCTAssertFalse(model.isWaitingForRenderer, "the wait should be over")
    }

    func testClosingTheVideoDropsAFileThatWasStillWaiting() throws {
        let model = try makeModel()
        let url = directory.appendingPathComponent("no-audio.mp4")
        model.play(url, from: [url], directory: nil)

        model.closeVideo()

        XCTAssertFalse(model.isWaitingForRenderer)
        model.videoView?.onRendererReady?()
        XCTAssertNil(
            model.playerState.currentURL,
            "a window closed while waiting should not start playing afterwards"
        )
    }

    private func makeModel() throws -> AppModel {
        let model = AppModel(
            folderLibrary: nil,
            progressStore: PlaybackProgressStore(
                storageURL: directory.appendingPathComponent("progress.json")
            )
        )
        try XCTSkipIf(model.engine == nil, "libmpv is not installed")
        return model
    }
}
