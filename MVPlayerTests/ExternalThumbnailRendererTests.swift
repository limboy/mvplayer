import AppKit
import XCTest
@testable import MVPlayer

final class ExternalThumbnailRendererTests: XCTestCase {
    func testFFmpegArgumentsSeekBeforeTheInputAndEmitOneFrame() {
        let arguments = ExternalThumbnailRenderer.ffmpegArguments(
            for: URL(fileURLWithPath: "/videos/clip.mkv"),
            at: 42,
            maximumWidth: 320
        )

        guard
            let seekIndex = arguments.firstIndex(of: "-ss"),
            let inputIndex = arguments.firstIndex(of: "-i")
        else {
            return XCTFail("The arguments should seek and take an input.")
        }
        XCTAssertLessThan(seekIndex, inputIndex)
        XCTAssertEqual(arguments[seekIndex + 1], "42")
        XCTAssertEqual(arguments[inputIndex + 1], "/videos/clip.mkv")
        XCTAssertTrue(arguments.contains("-frames:v"))
        XCTAssertEqual(arguments.last, "pipe:1")
        XCTAssertTrue(arguments.contains("scale=w='min(iw,320)':h=-2"))
    }

    func testMPVArgumentsWriteASingleFrameIntoTheOutputDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/thumbs", isDirectory: true)
        let arguments = ExternalThumbnailRenderer.mpvArguments(
            for: URL(fileURLWithPath: "/videos/-odd-name.mkv"),
            at: 7,
            outputDirectory: directory
        )

        XCTAssertTrue(arguments.contains("--frames=1"))
        XCTAssertTrue(arguments.contains("--start=7"))
        XCTAssertTrue(arguments.contains("--vo-image-outdir=/tmp/thumbs"))
        // A file name starting with a dash must not be read as an option.
        XCTAssertEqual(arguments.suffix(2), ["--", "/videos/-odd-name.mkv"])
    }

    func testLocateToolPrefersTheEnvironmentOverride() {
        let tool = ExternalThumbnailRenderer.locateTool(
            environment: [ExternalThumbnailRenderer.ffmpegPathVariable: "/bin/echo"]
        )

        XCTAssertEqual(tool, .ffmpeg(URL(fileURLWithPath: "/bin/echo")))
    }

    func testLocateToolFallsBackToMPVWhenFFmpegIsMissing() {
        let tool = ExternalThumbnailRenderer.locateTool(
            environment: [
                ExternalThumbnailRenderer.ffmpegPathVariable: "/does-not-exist/ffmpeg",
                ExternalThumbnailRenderer.mpvPathVariable: "/bin/echo",
            ],
            fileManager: AllowlistFileManager(executables: ["/bin/echo"])
        )

        XCTAssertEqual(tool, .mpv(URL(fileURLWithPath: "/bin/echo")))
    }

    func testMissingToolProducesNoImage() async {
        let renderer = ExternalThumbnailRenderer(tool: nil)

        XCTAssertFalse(renderer.isAvailable)
        let image = await renderer.image(
            for: URL(fileURLWithPath: "/videos/clip.mkv"),
            at: 1
        )
        XCTAssertNil(image)
    }

    func testRendersAFrameFromAMatroskaFileAVFoundationCannotOpen() async throws {
        guard case .ffmpeg(let ffmpeg)? = ExternalThumbnailRenderer.locateTool() else {
            throw XCTSkip("ffmpeg is not installed in this environment.")
        }
        let sample = try makeSampleMatroskaFile(using: ffmpeg)
        defer { try? FileManager.default.removeItem(at: sample) }

        let renderer = ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg))
        let image = await renderer.image(for: sample, at: 2, maximumWidth: 160)

        let unwrapped = try XCTUnwrap(image, "ffmpeg should decode a Matroska frame.")
        XCTAssertEqual(unwrapped.size.width, 160, accuracy: 1)
    }

    func testCancellationStopsRendering() async throws {
        guard case .ffmpeg(let ffmpeg)? = ExternalThumbnailRenderer.locateTool() else {
            throw XCTSkip("ffmpeg is not installed in this environment.")
        }
        let sample = try makeSampleMatroskaFile(using: ffmpeg)
        defer { try? FileManager.default.removeItem(at: sample) }

        let renderer = ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg))
        let task = Task { await renderer.image(for: sample, at: 2) }
        task.cancel()

        let image = await task.value
        XCTAssertNil(image)
    }

    /// Cancelling while the process is starting used to terminate a task that
    /// had not launched yet, which raises an Objective-C exception.
    func testCancellingAroundLaunchNeverRaises() async throws {
        guard case .ffmpeg(let ffmpeg)? = ExternalThumbnailRenderer.locateTool() else {
            throw XCTSkip("ffmpeg is not installed in this environment.")
        }
        let sample = try makeSampleMatroskaFile(using: ffmpeg)
        defer { try? FileManager.default.removeItem(at: sample) }

        let renderer = ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg))
        for delay in [0, 50, 200, 1_000, 5_000, 20_000] as [UInt64] {
            let task = Task { await renderer.image(for: sample, at: 2) }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000)
            }
            task.cancel()
            _ = await task.value
        }
    }

    private func makeSampleMatroskaFile(using ffmpeg: URL) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerThumbnailSample-\(UUID().uuidString).mkv")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "lavfi",
            "-i", "testsrc=size=320x180:rate=10",
            "-t", "5",
            "-c:v", "libx264",
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

/// Reports only the listed paths as executable so the fallback order can be
/// exercised without depending on what is installed on the host.
private final class AllowlistFileManager: FileManager {
    private let executables: Set<String>

    init(executables: Set<String>) {
        self.executables = executables
        super.init()
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }
}
