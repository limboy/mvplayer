import AppKit
import XCTest
@testable import MVPlayer

@MainActor
final class ThumbnailFilmstripTests: XCTestCase {
    func testShortFilesNeverGoFinerThanTheMinimumInterval() {
        XCTAssertEqual(ThumbnailFilmstrip.interval(for: 30), ThumbnailFilmstrip.minimumInterval)
        XCTAssertEqual(ThumbnailFilmstrip.interval(for: 0), ThumbnailFilmstrip.minimumInterval)
        XCTAssertEqual(ThumbnailFilmstrip.interval(for: .infinity), ThumbnailFilmstrip.minimumInterval)
    }

    func testLongFilesSpreadTheSlotBudgetAcrossTheDuration() {
        // Two hours across the slot budget, so the strip stays the same size no
        // matter how long the file is.
        let interval = ThumbnailFilmstrip.interval(for: 7_200)

        XCTAssertEqual(interval, 7_200 / Double(ThumbnailFilmstrip.targetSlotCount), accuracy: 0.001)
    }

    func testTimesSnapToTheNearestSlot() {
        let filmstrip = ThumbnailFilmstrip(
            url: URL(fileURLWithPath: "/videos/clip.mkv"),
            duration: 600,
            renderer: ExternalThumbnailRenderer(tool: nil)
        )

        XCTAssertEqual(filmstrip.interval, 3, accuracy: 0.001)
        XCTAssertEqual(filmstrip.slot(for: 0), 0)
        XCTAssertEqual(filmstrip.slot(for: 1.4), 0)
        XCTAssertEqual(filmstrip.slot(for: 1.6), 1)
        XCTAssertEqual(filmstrip.slot(for: 300), 100)
        // Negative positions can arrive from a drag past the left edge.
        XCTAssertEqual(filmstrip.slot(for: -5), 0)
    }

    func testFilmstripArgumentsMakeOneKeyframeOnlyPassOverTheFile() {
        let arguments = ExternalThumbnailRenderer.filmstripArguments(
            for: URL(fileURLWithPath: "/videos/clip.mkv"),
            interval: 2.5,
            maximumWidth: 192
        )

        guard let inputIndex = arguments.firstIndex(of: "-i") else {
            return XCTFail("The arguments should take an input.")
        }
        XCTAssertEqual(arguments[inputIndex + 1], "/videos/clip.mkv")
        // Key frame only decoding is what keeps a whole file pass affordable.
        guard let skipIndex = arguments.firstIndex(of: "-skip_frame") else {
            return XCTFail("The pass should skip non key frames.")
        }
        XCTAssertEqual(arguments[skipIndex + 1], "nokey")
        XCTAssertLessThan(skipIndex, inputIndex)
        XCTAssertTrue(arguments.contains("fps=1/2.5,scale=w='min(iw,192)':h=-2"))
        XCTAssertTrue(arguments.contains("mjpeg"))
        XCTAssertEqual(arguments.last, "pipe:1")
        // A single seek argument would limit the pass to one frame.
        XCTAssertFalse(arguments.contains("-ss"))
        XCTAssertFalse(arguments.contains("-frames:v"))
    }

    func testJPEGsAreSplitOutOfTheStreamAsTheyArrive() {
        let first = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let second = Data([0xFF, 0xD8, 0x03, 0xFF, 0xD9])
        var buffer = Data()

        // A partial frame yields nothing until its end marker lands.
        buffer.append(first.prefix(3))
        XCTAssertNil(ExternalThumbnailRenderer.takeJPEG(from: &buffer))

        buffer.append(first.dropFirst(3))
        buffer.append(second)
        XCTAssertEqual(ExternalThumbnailRenderer.takeJPEG(from: &buffer), first)
        XCTAssertEqual(ExternalThumbnailRenderer.takeJPEG(from: &buffer), second)
        XCTAssertNil(ExternalThumbnailRenderer.takeJPEG(from: &buffer))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testLeadingNoiseBeforeTheFirstFrameIsDiscarded() {
        var buffer = Data([0x00, 0x99]) + Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])

        XCTAssertEqual(
            ExternalThumbnailRenderer.takeJPEG(from: &buffer),
            Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        )
    }

    func testAMatroskaFilmstripCoversTheWholeTimeline() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv", seconds: 20)
        defer { try? FileManager.default.removeItem(at: sample) }

        let filmstrip = ThumbnailFilmstrip(
            url: sample,
            duration: 20,
            renderer: ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg))
        )
        filmstrip.start()
        try await waitForCompletion(of: filmstrip)

        // Frames land on whole slots, and reading is a plain lookup, which is
        // the point: hovering must not wait on a process. The tail matters as
        // much as the middle, because the last key frame arrives before the
        // last slot does.
        XCTAssertNotNil(filmstrip.frame(at: 0))
        XCTAssertNotNil(filmstrip.frame(at: 9.5))
        XCTAssertNotNil(filmstrip.frame(at: 18))
        XCTAssertNotNil(filmstrip.frame(at: 20))
    }

    func testAStripThatHasNotRunYetAnswersNothing() {
        let filmstrip = ThumbnailFilmstrip(
            url: URL(fileURLWithPath: "/videos/clip.mkv"),
            duration: 600,
            renderer: ExternalThumbnailRenderer(tool: nil)
        )

        // Hovering before the strip fills has to fall through to extracting a
        // single frame rather than being told there is nothing to show.
        XCTAssertNil(filmstrip.frame(at: 0))
        XCTAssertNil(filmstrip.frame(at: 300))
    }

    func testAnMP4FilmstripFallsBackToAVFoundationWithoutFFmpeg() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mp4", seconds: 20)
        defer { try? FileManager.default.removeItem(at: sample) }

        let filmstrip = ThumbnailFilmstrip(
            url: sample,
            duration: 20,
            renderer: ExternalThumbnailRenderer(tool: nil)
        )
        filmstrip.start()
        try await waitForCompletion(of: filmstrip)

        XCTAssertNotNil(filmstrip.frame(at: 0))
        XCTAssertNotNil(filmstrip.frame(at: 10))
    }

    func testMatroskaHasNoFilmstripWithoutFFmpeg() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv", seconds: 5)
        defer { try? FileManager.default.removeItem(at: sample) }

        let filmstrip = ThumbnailFilmstrip(
            url: sample,
            duration: 5,
            renderer: ExternalThumbnailRenderer(tool: nil)
        )
        filmstrip.start()
        try await waitForCompletion(of: filmstrip)

        // AVFoundation cannot open Matroska, so those files stay on the single
        // frame path rather than showing a broken strip.
        XCTAssertNil(filmstrip.frame(at: 2))
    }

    func testPreparingAFileMakesHoveringASynchronousLookup() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv", seconds: 20)
        defer { try? FileManager.default.removeItem(at: sample) }

        let provider = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg))
        )
        XCTAssertNil(provider.cachedImage(for: sample, at: 10))

        provider.prepare(for: sample, duration: 20)
        try await waitFor { provider.cachedImage(for: sample, at: 10) != nil }

        XCTAssertNotNil(provider.cachedImage(for: sample, at: 10))
    }

    private func waitForCompletion(of filmstrip: ThumbnailFilmstrip) async throws {
        try await waitFor { filmstrip.isComplete }
    }

    private func waitFor(
        timeout: Double = 30,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                return XCTFail("Timed out waiting for the filmstrip.")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func requireFFmpeg() throws -> URL {
        guard case .ffmpeg(let ffmpeg)? = ExternalThumbnailRenderer.locateTool() else {
            throw XCTSkip("ffmpeg is not installed in this environment.")
        }
        return ffmpeg
    }

    private func makeSample(
        using ffmpeg: URL,
        pathExtension: String,
        seconds: Int
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerFilmstripSample-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "lavfi",
            "-i", "testsrc=size=320x180:rate=10",
            "-t", String(seconds),
            "-c:v", "libx264",
            "-g", "20",
            "-pix_fmt", "yuv420p",
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
