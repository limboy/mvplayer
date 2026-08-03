import AVFoundation
import Foundation

struct MediaMetadata: Equatable, Sendable {
    let fileSize: Int64
    let duration: Double?
    let width: Int?
    let height: Int?
    let frameRate: Double?

    var detailText: String {
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
        return parts.joined(separator: "  ·  ")
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

    static func load(for url: URL) async -> MediaMetadata? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(values?.fileSize ?? 0)
        let asset = AVAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? .nan
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let videoTrack = videoTracks.first
        let naturalSize = try? await videoTrack?.load(.naturalSize)
        let width = naturalSize.map { Int(abs($0.width.rounded())) }
        let height = naturalSize.map { Int(abs($0.height.rounded())) }
        let frameRate = try? await videoTrack?.load(.nominalFrameRate)

        if fileSize == 0, !duration.isFinite, videoTrack == nil {
            return nil
        }
        return MediaMetadata(
            fileSize: fileSize,
            duration: duration.isFinite && duration > 0 ? duration : nil,
            width: width,
            height: height,
            frameRate: frameRate.map(Double.init)
        )
    }
}
