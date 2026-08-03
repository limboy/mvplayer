import Foundation

/// What a file says about itself, read by a command line tool rather than by
/// AVFoundation.
struct ProbedMetadata: Equatable, Sendable {
    var duration: Double?
    var width: Int?
    var height: Int?
    var frameRate: Double?

    var isEmpty: Bool {
        duration == nil && width == nil && height == nil && frameRate == nil
    }
}

/// Reads running time, dimensions and frame rate out of the containers
/// AVFoundation will not open.
///
/// Matroska is the one that matters — AVFoundation cannot open it at all, so a
/// .mkv answers with no tracks and no duration however ordinary its contents,
/// and the same file remuxed into MP4 answers everything. AVI and WebM fare no
/// better. `ExternalThumbnailRenderer` already reaches for these tools for the
/// same reason; this asks them the cheaper question.
enum ExternalMediaProbe {
    /// One file at a time. Opening a folder asks about every video in it at
    /// once, and a folder of Matroska is a folder of processes if nothing holds
    /// them in a line. Utility priority because nothing is waiting on the
    /// answer: rows show what they have and fill in when it arrives.
    private static let workQueue = DispatchQueue(
        label: "me.limboy.mvplayer.ExternalMediaProbe",
        qos: .utility
    )

    /// The probe to use, derived from whichever tool the thumbnail renderer
    /// found. ffprobe ships beside ffmpeg and is the cheaper of the two — it
    /// reads the headers, where mpv has to open the file and decode a frame.
    enum Tool: Equatable {
        case ffprobe(URL)
        case mpv(URL)
    }

    static func locateTool(
        thumbnailTool: ThumbnailTool? = ExternalThumbnailRenderer.locateTool(),
        fileManager: FileManager = .default
    ) -> Tool? {
        switch thumbnailTool {
        case .ffmpeg(let executable):
            // Beside the ffmpeg that was found, so an installation reached
            // through MVPLAYER_FFMPEG_PATH keeps its own pair.
            let ffprobe = executable
                .deletingLastPathComponent()
                .appendingPathComponent("ffprobe")
            guard fileManager.isExecutableFile(atPath: ffprobe.path) else { return nil }
            return .ffprobe(ffprobe)
        case .mpv(let executable):
            return .mpv(executable)
        case nil:
            return nil
        }
    }

    static func metadata(
        for url: URL,
        tool: Tool? = locateTool()
    ) async -> ProbedMetadata? {
        guard let tool else { return nil }
        let result: ProbedMetadata?
        switch tool {
        case .ffprobe(let executable):
            let data = await ExternalProcess.run(
                executable: executable,
                arguments: ffprobeArguments(for: url),
                on: workQueue
            )
            result = data.flatMap(parseFFprobe)
        case .mpv(let executable):
            let data = await ExternalProcess.run(
                executable: executable,
                arguments: mpvArguments(for: url),
                on: workQueue
            )
            result = data.flatMap { parseMPV(String(decoding: $0, as: UTF8.self)) }
        }
        guard let result, !result.isEmpty else { return nil }
        return result
    }

    static func ffprobeArguments(for url: URL) -> [String] {
        [
            "-v", "quiet",
            "-print_format", "json",
            "-show_entries", "format=duration:stream=width,height,r_frame_rate",
            // The first video stream, so a cover image or a second angle cannot
            // stand in for the picture.
            "-select_streams", "v:0",
            "--",
            url.path,
        ]
    }

    /// Whoever has mpv but not ffmpeg still gets an answer. `--frames=1` rather
    /// than `--frames=0`: the message is printed when playback starts, and with
    /// no frames to show it never does.
    static func mpvArguments(for url: URL) -> [String] {
        [
            "--no-config",
            "--vo=null",
            "--ao=null",
            "--no-sub",
            "--frames=1",
            "--term-playing-msg=\(mpvMarker) ${=duration} ${width} ${height} ${container-fps}",
            "--",
            url.path,
        ]
    }

    static let mpvMarker = "MVPLAYER-PROBE"

    private struct FFprobeOutput: Decodable {
        struct Format: Decodable {
            let duration: String?
        }

        struct Stream: Decodable {
            let width: Int?
            let height: Int?
            let r_frame_rate: String?
        }

        let format: Format?
        let streams: [Stream]?
    }

    static func parseFFprobe(_ data: Data) -> ProbedMetadata? {
        guard let output = try? JSONDecoder().decode(FFprobeOutput.self, from: data) else {
            return nil
        }
        let stream = output.streams?.first
        return ProbedMetadata(
            duration: output.format?.duration.flatMap(Double.init),
            width: stream?.width,
            height: stream?.height,
            frameRate: stream?.r_frame_rate.flatMap(parseRational)
        )
    }

    /// ffprobe reports a frame rate as the exact ratio the container carries,
    /// "24000/1001" rather than 23.976.
    static func parseRational(_ text: String) -> Double? {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard let first = parts.first, let numerator = Double(first) else { return nil }
        guard parts.count == 2 else { return numerator }
        guard let denominator = Double(parts[1]), denominator != 0 else { return nil }
        return numerator / denominator
    }

    static func parseMPV(_ output: String) -> ProbedMetadata? {
        guard let line = output
            .split(separator: "\n")
            .last(where: { $0.hasPrefix(mpvMarker) })
        else {
            return nil
        }
        // Anything mpv could not answer for comes back as its own property
        // name in braces, which parses as nothing and is left out.
        let fields = line.dropFirst(mpvMarker.count).split(separator: " ")
        func field(_ index: Int) -> String? {
            index < fields.count ? String(fields[index]) : nil
        }
        return ProbedMetadata(
            duration: field(0).flatMap(Double.init),
            width: field(1).flatMap(Int.init),
            height: field(2).flatMap(Int.init),
            frameRate: field(3).flatMap(Double.init)
        )
    }
}
