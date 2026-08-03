import AppKit
import XCTest
@testable import MVPlayer

@MainActor
final class MediaThumbnailProviderTests: XCTestCase {
    func testMatroskaFallsBackToTheExternalRenderer() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv")
        defer { try? FileManager.default.removeItem(at: sample) }

        let provider = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg))
        )
        let image = await provider.image(for: sample, at: 2)

        XCTAssertNotNil(image, "Matroska previews must come from the external renderer.")
    }

    func testMatroskaHasNoPreviewWithoutAnExternalTool() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv")
        defer { try? FileManager.default.removeItem(at: sample) }

        let provider = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: nil)
        )
        let image = await provider.image(for: sample, at: 2)

        XCTAssertNil(image, "AVFoundation is expected to fail on Matroska.")
    }

    func testMP4UsesAVFoundationWithoutAnExternalTool() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: sample) }

        let provider = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: nil)
        )
        let image = await provider.image(for: sample, at: 2)

        XCTAssertNotNil(image)
    }

    func testRepeatedRequestsForTheSameSecondAreCached() async throws {
        let ffmpeg = try requireFFmpeg()
        let sample = try makeSample(using: ffmpeg, pathExtension: "mkv")
        defer { try? FileManager.default.removeItem(at: sample) }

        let provider = MediaThumbnailProvider(
            external: ExternalThumbnailRenderer(tool: .ffmpeg(ffmpeg))
        )
        let firstImage = await provider.image(for: sample, at: 2.2)
        let secondImage = await provider.image(for: sample, at: 2.4)
        let first = try XCTUnwrap(firstImage)
        let second = try XCTUnwrap(secondImage)

        XCTAssertIdentical(first, second)
    }

    func testOnlyContainersAVFoundationClaimsAreProbed() {
        XCTAssertTrue(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip.mp4")))
        XCTAssertTrue(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip.MOV")))
        XCTAssertFalse(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip.mkv")))
        XCTAssertFalse(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip.webm")))
        XCTAssertFalse(MediaThumbnailProvider.isAudiovisualType(URL(fileURLWithPath: "/a/clip")))
    }

    private func requireFFmpeg() throws -> URL {
        guard case .ffmpeg(let ffmpeg)? = ExternalThumbnailRenderer.locateTool() else {
            throw XCTSkip("ffmpeg is not installed in this environment.")
        }
        return ffmpeg
    }

    private func makeSample(using ffmpeg: URL, pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerThumbnailSample-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
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
