import Combine
import XCTest
@testable import MVPlayer

/// Drives a real libmpv player, because the interesting failures here are
/// between threads and cannot be reproduced against a stub: mpv runs the wakeup
/// callback while holding its own client lock, so anything the app locks on
/// that path sits beneath mpv's lock and can deadlock a caller waiting to enter
/// mpv. Only an actual player exercises that ordering.
@MainActor
final class MPVPlayerEngineTests: XCTestCase {
    func testLoadingAFileDeliversEventsThroughTheWakeupCallback() async throws {
        let engine = try makeEngine()
        let sample = try makeSample()
        defer { try? FileManager.default.removeItem(at: sample) }

        engine.load(sample)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, engine.state.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }

        // load() issues a command and then sets a property, both of which reach
        // mpv from the main thread while mpv is calling back with events for
        // the same file. Holding a lock across either call deadlocks against
        // the wakeup callback, and the whole test hangs here instead of failing.
        XCTAssertFalse(engine.state.isLoading, "no event ever came back from mpv")

        // vo=libmpv has no output without a render context, which a headless
        // test cannot build, so mpv answers this load with VO_INIT_FAILED. That
        // it is reported at all is the point: the message travels an END_FILE
        // event through the wakeup callback, the drain, and the main actor.
        XCTAssertEqual(engine.state.errorMessage, "Playback failed (mpv error -16).")

        engine.shutdown()
        try await Task.sleep(for: .milliseconds(500))
    }

    func testShutdownIsSafeToRepeatWhileDrainsAreQueued() async throws {
        let engine = try makeEngine()
        for _ in 0..<50 {
            engine.scheduleEventDrain()
        }

        // The destroy runs once, behind every drain already queued. A second
        // and third call must not free the player again.
        engine.shutdown()
        engine.shutdown()
        engine.shutdown()
        try await Task.sleep(for: .milliseconds(500))
    }

    func testCommandsIssuedAfterShutdownAreDropped() async throws {
        let engine = try makeEngine()
        engine.shutdown()

        // Every one of these would reach a freed handle if the queue did not
        // drop work behind the destroy.
        engine.seek(to: 30)
        engine.setPaused(true)
        engine.setVolume(50)
        engine.setSubtitle(id: 1)
        engine.stop()
        try await Task.sleep(for: .milliseconds(500))
    }

    func testThePlaybackPositionIsPublishedAtAFixedRateRatherThanPerFrame() async throws {
        let engine = try makeEngine()
        // Audio only, because a headless test has no render context and mpv
        // would fail a video file on VO init before ever reporting a position.
        let sample = try makeSample(audioOnly: true)
        defer { try? FileManager.default.removeItem(at: sample) }

        var updates = 0
        let subscription = engine.state.$currentTime.sink { _ in updates += 1 }
        defer { subscription.cancel() }

        engine.load(sample)
        try await Task.sleep(for: .seconds(3))

        // Playing at all is half the assertion: a throttle that published
        // nothing would also satisfy the count.
        XCTAssertGreaterThan(engine.state.currentTime, 1, "the file did not play")

        // Three seconds at four a second, plus the reset and the subscription's
        // own first value. Unthrottled this file measures around seventeen a
        // second, and a video file reports one per decoded frame.
        XCTAssertLessThan(updates, 20, "the position is not being rationed")

        engine.shutdown()
        try await Task.sleep(for: .milliseconds(500))
    }

    private func makeEngine() throws -> MPVPlayerEngine {
        do {
            return try MPVPlayerEngine(state: PlayerState())
        } catch {
            throw XCTSkip("libmpv is not available in this environment: \(error)")
        }
    }

    private func makeSample(audioOnly: Bool = false) throws -> URL {
        guard case .ffmpeg(let ffmpeg)? = ExternalThumbnailRenderer.locateTool() else {
            throw XCTSkip("ffmpeg is not installed in this environment.")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerEngineSample-\(UUID().uuidString)")
            .appendingPathExtension(audioOnly ? "m4a" : "mp4")
        let source = audioOnly
            ? ["-i", "sine=frequency=440"]
            : ["-i", "testsrc=size=320x180:rate=10"]
        let codec = audioOnly
            ? ["-c:a", "aac"]
            : ["-c:v", "libx264", "-pix_fmt", "yuv420p"]
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "lavfi",
        ] + source + [
            "-t", "10",
        ] + codec + [
            url.path,
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg could not encode the test fixture.")
        }
        return url
    }
}
