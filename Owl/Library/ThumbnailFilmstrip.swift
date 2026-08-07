import AVFoundation
import AppKit
import Foundation

/// A coarse grid of preview frames covering a whole file, filled in the
/// background as soon as a file opens.
///
/// Extracting a frame on demand costs a process launch and a seek, which is
/// fast enough on its own but far too slow to keep up with a pointer moving
/// across the scrubber: every move cancels the request before it finishes, so
/// the preview only ever catches up once the pointer stops. Reading the strip
/// is a dictionary lookup, so hovering can stay in step with the pointer.
@MainActor
final class ThumbnailFilmstrip {
    /// How many frames to spread across the file. Enough that neighbouring
    /// pointer positions rarely land on the same slot, few enough that the
    /// strip stays small and finishes quickly.
    static let targetSlotCount = 200

    /// Slots never get finer than this. Below a second or so the extra frames
    /// cost a longer pass over the file without being distinguishable.
    static let minimumInterval: Double = 1

    let url: URL
    let duration: Double
    let interval: Double

    private var frames: [Int: NSImage] = [:]
    private var highestSlot = -1
    private var task: Task<Void, Never>?
    private let renderer: ExternalThumbnailRenderer

    /// Whether the strip has every slot it is ever going to get.
    private(set) var isComplete = false

    init(url: URL, duration: Double, renderer: ExternalThumbnailRenderer) {
        self.url = url
        self.duration = duration
        self.renderer = renderer
        self.interval = Self.interval(for: duration)
    }

    static func interval(for duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return minimumInterval }
        return max(duration / Double(targetSlotCount), minimumInterval)
    }

    func slot(for seconds: Double) -> Int {
        max(0, Int((seconds / interval).rounded()))
    }

    /// How far a lookup may stray from the slot it asked for when a frame is
    /// missing. The slot budget keeps this to roughly one percent of the
    /// running time.
    static let neighbourSlotBudget = 2

    /// The nearest frame already extracted, or `nil` while the strip has not
    /// reached this part of the file yet. Ties go to the earlier frame, which
    /// is the one a position on the timeline has already passed.
    func frame(at seconds: Double) -> NSImage? {
        var target = slot(for: seconds)
        // A file ends between slots: the last key frame can land several slots
        // short of the running time. Once the strip has everything it is going
        // to get, its final frame is the right one for the rest of the
        // timeline. Before that, the highest slot is only how far the pass has
        // read, so positions beyond it stay unanswered.
        if isComplete, target > highestSlot {
            target = highestSlot
        }
        for distance in 0...Self.neighbourSlotBudget {
            if let frame = frames[target - distance] {
                return frame
            }
            if let frame = frames[target + distance] {
                return frame
            }
        }
        return nil
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for await frame in self.frameStream() {
                guard !Task.isCancelled else { return }
                self.frames[frame.index] = frame.image
                self.highestSlot = max(self.highestSlot, frame.index)
            }
            self.isComplete = true
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Frames come from ffmpeg when it is installed, because one pass over the
    /// file covers the whole timeline. Without it, AVFoundation walks the same
    /// grid; that only works for the containers it can open, and it yields
    /// nothing for the rest, leaving those files on the single frame path.
    private func frameStream() -> AsyncStream<FilmstripFrame> {
        if renderer.isFFmpegAvailable {
            return renderer.filmstripFrames(for: url, interval: interval)
        }
        return Self.avFoundationFrames(for: url, duration: duration, interval: interval)
    }

    private static func avFoundationFrames(
        for url: URL,
        duration: Double,
        interval: Double
    ) -> AsyncStream<FilmstripFrame> {
        guard MediaThumbnailProvider.isAudiovisualType(url), duration > 0, interval > 0 else {
            return AsyncStream { $0.finish() }
        }
        let slots = max(1, Int(duration / interval))
        let times = (0...slots).map {
            CMTime(seconds: Double($0) * interval, preferredTimescale: 600)
        }
        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 480, height: 480)
                // Snapping to the nearest key frame is what makes walking the
                // whole timeline affordable.
                generator.requestedTimeToleranceBefore = .positiveInfinity
                generator.requestedTimeToleranceAfter = .positiveInfinity

                for await result in generator.images(for: times) {
                    guard !Task.isCancelled else { break }
                    guard let cgImage = try? result.image else { continue }
                    let index = Int((result.requestedTime.seconds / interval).rounded())
                    continuation.yield(
                        FilmstripFrame(
                            index: index,
                            image: NSImage(cgImage: cgImage, size: .zero)
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
