import XCTest
@testable import MVPlayer

/// Checks against the power manager rather than against the app's own
/// bookkeeping, because a flag flipped in the right order still lets the screen
/// dim if the assertion never reaches the system.
@MainActor
final class PlaybackSleepPreventionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerSleepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheDisplayIsHeldAwakeOnlyWhileAVideoIsPlaying() async throws {
        let appModel = makeAppModel()
        XCTAssertFalse(Self.isHoldingDisplayAwake(), "an idle player should hold nothing")

        appModel.playerState.currentURL = URL(fileURLWithPath: "/tmp/movie.mp4")
        appModel.playerState.isPaused = false
        try await settle()
        XCTAssertTrue(Self.isHoldingDisplayAwake(), "playing should keep the display awake")

        appModel.playerState.isPaused = true
        try await settle()
        XCTAssertFalse(Self.isHoldingDisplayAwake(), "pausing should let the display sleep")
    }

    func testClosingAVideoReleasesTheDisplay() async throws {
        let appModel = makeAppModel()
        appModel.playerState.currentURL = URL(fileURLWithPath: "/tmp/movie.mp4")
        appModel.playerState.isPaused = false
        try await settle()
        XCTAssertTrue(Self.isHoldingDisplayAwake())

        appModel.closeVideo()
        try await settle()

        XCTAssertFalse(Self.isHoldingDisplayAwake(), "closing should let the display sleep")
    }

    private func makeAppModel() -> AppModel {
        AppModel(
            folderLibrary: FolderLibrary(
                storageURL: directory.appendingPathComponent("library.json"),
                startWatching: false
            ),
            progressStore: PlaybackProgressStore(
                storageURL: directory.appendingPathComponent("progress.json")
            )
        )
    }

    /// The activity is taken from a Combine sink, so it lands a turn later.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Whether this process in particular holds the assertion. The global count
    /// is no good: any other app playing something holds one too.
    private static func isHoldingDisplayAwake() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let pid = "pid \(ProcessInfo.processInfo.processIdentifier)("
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .contains { $0.contains(pid) && $0.contains("PreventUserIdleDisplaySleep") }
    }
}
