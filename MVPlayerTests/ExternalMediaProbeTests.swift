import XCTest
@testable import MVPlayer

final class ExternalMediaProbeTests: XCTestCase {
    func testParsesFFprobeOutput() throws {
        let json = Data("""
        {
            "programs": [],
            "streams": [{"width": 1920, "height": 1080, "r_frame_rate": "24000/1001"}],
            "format": {"duration": "5361.472000"}
        }
        """.utf8)

        let probed = try XCTUnwrap(ExternalMediaProbe.parseFFprobe(json))
        XCTAssertEqual(probed.duration, 5_361.472)
        XCTAssertEqual(probed.width, 1_920)
        XCTAssertEqual(probed.height, 1_080)
        XCTAssertEqual(try XCTUnwrap(probed.frameRate), 23.976, accuracy: 0.001)
    }

    func testFFprobeOutputWithoutAVideoStreamStillCarriesTheDuration() throws {
        let json = Data("""
        {"streams": [], "format": {"duration": "183.000000"}}
        """.utf8)

        let probed = try XCTUnwrap(ExternalMediaProbe.parseFFprobe(json))
        XCTAssertEqual(probed.duration, 183)
        XCTAssertNil(probed.width)
        XCTAssertNil(probed.frameRate)
    }

    func testUnreadableFFprobeOutputIsRejected() {
        XCTAssertNil(ExternalMediaProbe.parseFFprobe(Data("not json".utf8)))
    }

    func testParsesTheLineMPVPrints() throws {
        let output = """
        (+) Video --vid=1 (h264 1920x1080 24.000fps)
        \(ExternalMediaProbe.mpvMarker) 7.000000 1920 1080 24
        Exiting... (End of file)
        """

        let probed = try XCTUnwrap(ExternalMediaProbe.parseMPV(output))
        XCTAssertEqual(probed.duration, 7)
        XCTAssertEqual(probed.width, 1_920)
        XCTAssertEqual(probed.height, 1_080)
        XCTAssertEqual(probed.frameRate, 24)
    }

    /// mpv writes a property it cannot answer for as its own name in braces.
    func testMPVFieldsThatCameBackUnansweredAreLeftOut() throws {
        let output = "\(ExternalMediaProbe.mpvMarker) 7.000000 1920 1080 ${container-fps}"

        let probed = try XCTUnwrap(ExternalMediaProbe.parseMPV(output))
        XCTAssertEqual(probed.duration, 7)
        XCTAssertNil(probed.frameRate)
    }

    func testOutputWithoutTheMarkerIsRejected() {
        XCTAssertNil(ExternalMediaProbe.parseMPV("Exiting... (Errors when loading file)"))
    }

    func testFFprobeIsFoundBesideTheFFmpegThatWasLocated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ffmpeg = directory.appendingPathComponent("ffmpeg")
        let ffprobe = directory.appendingPathComponent("ffprobe")
        for tool in [ffmpeg, ffprobe] {
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        XCTAssertEqual(
            ExternalMediaProbe.locateTool(thumbnailTool: .ffmpeg(ffmpeg)),
            .ffprobe(ffprobe)
        )

        // An ffmpeg installed without its probe falls through rather than
        // pointing at something that is not there.
        try FileManager.default.removeItem(at: ffprobe)
        XCTAssertNil(ExternalMediaProbe.locateTool(thumbnailTool: .ffmpeg(ffmpeg)))

        XCTAssertNil(ExternalMediaProbe.locateTool(thumbnailTool: nil))
    }

    /// The case this exists for: AVFoundation opens no Matroska file, so
    /// everything but the file size has to come from the probe.
    func testMatroskaMetadataIsReadThoughAVFoundationCannotOpenTheFile() async throws {
        let sample = try makeMatroskaSample()
        defer { try? FileManager.default.removeItem(at: sample) }

        let loaded = await MediaMetadata.load(for: sample)
        let metadata = try XCTUnwrap(loaded)
        XCTAssertEqual(try XCTUnwrap(metadata.duration), 7, accuracy: 0.5)
        XCTAssertEqual(metadata.width, 1_920)
        XCTAssertEqual(metadata.height, 1_080)
        XCTAssertEqual(try XCTUnwrap(metadata.frameRate), 24, accuracy: 0.1)
        XCTAssertGreaterThan(metadata.fileSize, 0)

        XCTAssertEqual(
            metadata.summaryParts.prefix(3).joined(separator: " "),
            "00:07 1920×1080 24 fps"
        )
    }

    /// Both tools read the same file the same way.
    func testMPVReadsWhatFFprobeReads() async throws {
        guard case .mpv(let mpv)? = ExternalThumbnailRenderer.locateTool(
            environment: [:],
            fileManager: MPVOnlyFileManager()
        ) else {
            throw XCTSkip("mpv is not installed in this environment.")
        }
        let sample = try makeMatroskaSample()
        defer { try? FileManager.default.removeItem(at: sample) }

        let probed = await ExternalMediaProbe.metadata(for: sample, tool: .mpv(mpv))
        let viaMPV = try XCTUnwrap(probed)
        XCTAssertEqual(try XCTUnwrap(viaMPV.duration), 7, accuracy: 0.5)
        XCTAssertEqual(viaMPV.width, 1_920)
        XCTAssertEqual(viaMPV.height, 1_080)
        XCTAssertEqual(try XCTUnwrap(viaMPV.frameRate), 24, accuracy: 0.1)
    }

    func testAFileNeitherToolCanOpenProducesNothing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerProbe-\(UUID().uuidString).mkv")
        try Data("not a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let probed = await ExternalMediaProbe.metadata(for: url)
        XCTAssertNil(probed)
    }

    private func makeMatroskaSample() throws -> URL {
        guard case .ffmpeg(let ffmpeg)? = ExternalThumbnailRenderer.locateTool() else {
            throw XCTSkip("ffmpeg is not installed in this environment.")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MVPlayerProbeSample-\(UUID().uuidString)")
            .appendingPathExtension("mkv")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "lavfi",
            "-i", "testsrc=size=1920x1080:rate=24",
            "-t", "7",
            "-c:v", "libx264",
            "-preset", "ultrafast",
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

/// Hides ffmpeg from tool discovery so the mpv branch can be reached on a host
/// that has both.
private final class MPVOnlyFileManager: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool {
        guard !path.hasSuffix("ffmpeg") else { return false }
        return super.isExecutableFile(atPath: path)
    }
}
