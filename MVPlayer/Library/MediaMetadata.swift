import AVFoundation
import Foundation

struct MediaMetadata: Equatable, Sendable {
    let fileSize: Int64
    let duration: Double?
    let width: Int?
    let height: Int?
    let frameRate: Double?

    /// What is worth saying about the file, in reading order, leaving out
    /// anything it did not answer for.
    ///
    /// Kept as pieces rather than one string because the status bar showing
    /// them drops the later ones when the window is too narrow to hold them
    /// all, and the running time is the one to keep longest.
    var summaryParts: [String] {
        var parts: [String] = []
        if let duration, duration.isFinite, duration > 0 {
            parts.append(Self.timeString(duration))
        }
        if let width, let height, width > 0, height > 0 {
            parts.append("\(width)×\(height)")
        }
        if let frameRate, frameRate.isFinite, frameRate > 0 {
            parts.append(String(format: "%.2g fps", frameRate))
        }
        if fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
        }
        return parts
    }

    private static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    /// Reads what the file has to say about itself.
    ///
    /// AVFoundation answers first, and for a Matroska, AVI or WebM file it
    /// answers nothing at all: it cannot open those containers, so there is no
    /// duration and no video track to ask about the picture, however ordinary
    /// the contents. The row was left showing a file size and four blanks. When
    /// that happens the question goes to ffprobe or mpv instead, the same tools
    /// the thumbnails already fall back to. With neither installed the row
    /// keeps its file size, which is read from the filesystem and does not
    /// depend on anything being able to open the file.
    static func load(for url: URL) async -> MediaMetadata? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(values?.fileSize ?? 0)
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? .nan
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let videoTrack = videoTracks.first
        let naturalSize = try? await videoTrack?.load(.naturalSize)
        var width = naturalSize.map { Int(abs($0.width.rounded())) }
        var height = naturalSize.map { Int(abs($0.height.rounded())) }
        var frameRate = (try? await videoTrack?.load(.nominalFrameRate)).map(Double.init)
        var seconds = duration.isFinite && duration > 0 ? duration : nil

        if videoTrack == nil || seconds == nil,
           let probed = await ExternalMediaProbe.metadata(for: url)
        {
            seconds = seconds ?? probed.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            width = width ?? probed.width
            height = height ?? probed.height
            frameRate = frameRate ?? probed.frameRate
        }

        if fileSize == 0, seconds == nil, width == nil {
            return nil
        }
        return MediaMetadata(
            fileSize: fileSize,
            duration: seconds,
            width: width,
            height: height,
            frameRate: frameRate
        )
    }
}
