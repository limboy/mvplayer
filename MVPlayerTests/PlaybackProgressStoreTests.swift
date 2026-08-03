import Foundation
import XCTest
@testable import MVPlayer

@MainActor
final class PlaybackProgressStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerProgressTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testProgressPersistsAndRestores() throws {
        let storageURL = temporaryDirectory.appendingPathComponent("progress.json")
        let video = temporaryDirectory.appendingPathComponent("lesson.mp4")
        try Data().write(to: video)
        let store = PlaybackProgressStore(storageURL: storageURL)

        store.record(url: video, position: 120, duration: 600)

        let restored = PlaybackProgressStore(storageURL: storageURL)
        XCTAssertEqual(restored.progress(for: video)?.position, 120)
    }

    func testNearEndProgressIsMarkedCompleted() {
        let store = PlaybackProgressStore(
            storageURL: temporaryDirectory.appendingPathComponent("progress.json")
        )
        let video = temporaryDirectory.appendingPathComponent("finished.mkv")

        store.record(url: video, position: 590, duration: 600)

        XCTAssertTrue(store.progress(for: video)?.isCompleted == true)
    }
}
