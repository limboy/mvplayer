import AppKit
import Foundation

/// A command line frame extractor discovered on the host.
enum ThumbnailTool: Equatable, Sendable {
    case ffmpeg(URL)
    case mpv(URL)
}

/// One frame of a filmstrip, tagged with its slot so callers can place it on
/// the timeline without tracking how many frames they have seen.
struct FilmstripFrame: @unchecked Sendable {
    let index: Int
    let image: NSImage
}

/// Extracts preview frames with the ffmpeg command line tools bundled inside
/// the app (or, failing that, a Homebrew install on the host). AVFoundation
/// cannot open most Matroska, AVI, or WebM files, so for those containers
/// this is the only source of previews.
final class ExternalThumbnailRenderer: Sendable {
    static let ffmpegPathVariable = "MVPLAYER_FFMPEG_PATH"
    static let mpvPathVariable = "MVPLAYER_MPV_PATH"

    // One frame at a time. Scrubbing cancels and replaces requests quickly,
    // and a serial queue keeps that from turning into a burst of processes.
    private static let workQueue = DispatchQueue(
        label: "me.limboy.mvplayer.ExternalThumbnailRenderer",
        qos: .userInitiated
    )

    // Filmstrips run for as long as it takes to read a whole file, so they get
    // their own queue instead of blocking the single frame requests behind it.
    private static let filmstripQueue = DispatchQueue(
        label: "me.limboy.mvplayer.ExternalThumbnailRenderer.filmstrip",
        qos: .utility
    )

    let tool: ThumbnailTool?

    init(tool: ThumbnailTool? = ExternalThumbnailRenderer.locateTool()) {
        self.tool = tool
    }

    var isAvailable: Bool { tool != nil }

    /// Whether filmstrips are possible. mpv writes frames one file at a time,
    /// so only ffmpeg can stream a whole strip from a single pass.
    var isFFmpegAvailable: Bool {
        if case .ffmpeg = tool { return true }
        return false
    }

    func image(for url: URL, at seconds: Int, maximumEdge: Int = 480) async -> NSImage? {
        switch tool {
        case .ffmpeg(let executable):
            let arguments = Self.ffmpegArguments(
                for: url,
                at: seconds,
                maximumEdge: maximumEdge
            )
            guard
                let data = await ExternalProcess.run(
                    executable: executable,
                    arguments: arguments,
                    on: Self.workQueue
                ),
                !data.isEmpty
            else {
                return nil
            }
            return NSImage(data: data)
        case .mpv(let executable):
            return await Self.mpvImage(executable: executable, url: url, seconds: seconds)
        case nil:
            return nil
        }
    }

    /// Streams evenly spaced frames covering the whole file, in order, as one
    /// process writes them. A single pass costs about as much as a handful of
    /// individual seeks, so this is how previews become instant instead of
    /// waiting on a process per hovered position.
    ///
    /// The frame at `index` is the one at `Double(index) * interval` seconds.
    /// Only ffmpeg can do this; other tools produce an empty strip and leave
    /// callers on the single frame path.
    func filmstripFrames(
        for url: URL,
        interval: Double,
        maximumEdge: Int = 480
    ) -> AsyncStream<FilmstripFrame> {
        guard case .ffmpeg(let executable) = tool, interval > 0, interval.isFinite else {
            return AsyncStream { $0.finish() }
        }
        let arguments = Self.filmstripArguments(
            for: url,
            interval: interval,
            maximumEdge: maximumEdge
        )
        return AsyncStream { continuation in
            let box = ProcessBox()
            continuation.onTermination = { _ in box.cancel() }
            Self.filmstripQueue.async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                guard !box.isCancelled, (try? process.run()) != nil else {
                    return continuation.finish()
                }
                guard box.adopt(process) else {
                    process.terminate()
                    process.waitUntilExit()
                    return continuation.finish()
                }

                let handle = output.fileHandleForReading
                var buffer = Data()
                var index = 0
                while
                    let chunk = try? handle.read(upToCount: 64 * 1_024),
                    !chunk.isEmpty
                {
                    buffer.append(chunk)
                    while let frame = Self.takeJPEG(from: &buffer) {
                        if let image = NSImage(data: frame) {
                            continuation.yield(FilmstripFrame(index: index, image: image))
                        }
                        index += 1
                    }
                }

                process.waitUntilExit()
                box.finish()
                continuation.finish()
            }
        }
    }

    /// Removes the first complete JPEG from `buffer`, or returns `nil` when one
    /// has not arrived yet. Entropy coded data escapes its own `FF` bytes, so
    /// an end of image marker can only ever mean the end of a frame.
    static func takeJPEG(from buffer: inout Data) -> Data? {
        let start = Data([0xFF, 0xD8])
        let end = Data([0xFF, 0xD9])
        guard
            let startRange = buffer.firstRange(of: start),
            let endRange = buffer.firstRange(of: end, in: startRange.upperBound..<buffer.endIndex)
        else {
            return nil
        }
        let frame = buffer[startRange.lowerBound..<endRange.upperBound]
        buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
        return Data(frame)
    }

    /// How preview frames are sized.
    ///
    /// A decoder hands back frames in storage dimensions, which for a file with
    /// non square pixels — screen recordings and phone footage often are — is
    /// not the shape it plays at: this project's own sample stores a portrait
    /// video as 1304x1080, which is nearly square. The first pass stretches by
    /// the sample aspect ratio, so the frame is shaped like the video, and the
    /// second fits it inside a square box, the same bound AVFoundation is given
    /// on the other extraction path. `sar` is 0 when a file does not say, which
    /// is the pixels being square.
    static func scaleFilter(maximumEdge: Int) -> String {
        "scale=w='if(gt(sar,0),iw*sar,iw)':h='ih',setsar=1,"
            + "scale=w='min(iw,\(maximumEdge))':h='min(ih,\(maximumEdge))'"
            + ":force_original_aspect_ratio=decrease:force_divisible_by=2"
    }

    static func filmstripArguments(
        for url: URL,
        interval: Double,
        maximumEdge: Int
    ) -> [String] {
        [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            // Decoding key frames only turns a full pass over the file into a
            // fraction of a second. The frames land on the nearest key frame
            // rather than the exact instant, which is what a scrubbing preview
            // wants anyway.
            "-skip_frame", "nokey",
            "-i", url.path,
            "-an", "-sn", "-dn",
            "-vf", "fps=1/\(String(format: "%g", interval)),"
                + scaleFilter(maximumEdge: maximumEdge),
            // JPEG rather than PNG: a strip is hundreds of frames, and at this
            // size the compression artefacts are invisible.
            "-q:v", "6",
            "-f", "image2pipe",
            "-vcodec", "mjpeg",
            "pipe:1",
        ]
    }

    static func locateTool(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> ThumbnailTool? {
        let bundledFFmpeg = bundle.resourceURL?
            .appendingPathComponent("bin/ffmpeg", isDirectory: false).path
        let ffmpegCandidates = [environment[ffmpegPathVariable]].compactMap { $0 }
            + [bundledFFmpeg].compactMap { $0 }
            + [
                "/opt/homebrew/bin/ffmpeg",
                "/opt/homebrew/opt/ffmpeg/bin/ffmpeg",
                "/usr/local/bin/ffmpeg",
            ]
        if let path = ffmpegCandidates.first(where: fileManager.isExecutableFile(atPath:)) {
            return .ffmpeg(URL(fileURLWithPath: path))
        }

        let mpvCandidates = [environment[mpvPathVariable]].compactMap { $0 } + [
            "/opt/homebrew/bin/mpv",
            "/opt/homebrew/opt/mpv/bin/mpv",
            "/usr/local/bin/mpv",
        ]
        if let path = mpvCandidates.first(where: fileManager.isExecutableFile(atPath:)) {
            return .mpv(URL(fileURLWithPath: path))
        }

        return nil
    }

    static func ffmpegArguments(
        for url: URL,
        at seconds: Int,
        maximumEdge: Int
    ) -> [String] {
        [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            // Seeking before the input decodes from the preceding key frame
            // instead of from the start of the file, which is what keeps
            // scrubbing previews fast.
            "-ss", String(seconds),
            "-i", url.path,
            "-frames:v", "1",
            "-an", "-sn", "-dn",
            "-vf", scaleFilter(maximumEdge: maximumEdge),
            "-f", "image2pipe",
            "-vcodec", "png",
            "pipe:1",
        ]
    }

    static func mpvArguments(
        for url: URL,
        at seconds: Int,
        outputDirectory: URL
    ) -> [String] {
        [
            "--no-config",
            "--really-quiet",
            "--no-audio",
            "--no-sub",
            "--frames=1",
            "--start=\(seconds)",
            "--vo=image",
            "--vo-image-format=png",
            "--vo-image-outdir=\(outputDirectory.path)",
            "--",
            url.path,
        ]
    }

    /// mpv can only write frames into a directory, so the fallback renders
    /// into a scratch directory and reads the single frame back.
    private static func mpvImage(
        executable: URL,
        url: URL,
        seconds: Int
    ) async -> NSImage? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("MVPlayerThumbnails", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer { try? fileManager.removeItem(at: directory) }

        let arguments = mpvArguments(for: url, at: seconds, outputDirectory: directory)
        guard await ExternalProcess.run(
            executable: executable,
            arguments: arguments,
            on: workQueue
        ) != nil else {
            return nil
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        guard let frame = contents.first(where: { $0.pathExtension.lowercased() == "png" }) else {
            return nil
        }
        return NSImage(contentsOf: frame)
    }
}
