import AVFoundation
import AppKit
import Foundation

@MainActor
final class MediaThumbnailProvider {
    static let shared = MediaThumbnailProvider()

    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL, at seconds: Double) async -> NSImage? {
        let bucket = max(0, Int(seconds.rounded()))
        let key = "\(url.standardizedFileURL.path)#\(bucket)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image: NSImage? = await withCheckedContinuation {
            (continuation: CheckedContinuation<NSImage?, Never>) in
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 220)
            let time = CMTime(seconds: Double(bucket), preferredTimescale: 600)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
                guard let cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSImage(cgImage: cgImage, size: .zero))
            }
        }

        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }
}
