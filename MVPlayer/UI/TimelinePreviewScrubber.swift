import AppKit
import SwiftUI

struct TimelinePreviewScrubber: View {
    let currentTime: Double
    let duration: Double
    let url: URL?
    @Binding var isSeeking: Bool
    @Binding var seekValue: Double
    let onCommit: (Double) -> Void

    @State private var previewTime: Double?
    @State private var previewImage: NSImage?
    @State private var thumbnailTask: Task<Void, Never>?

    private let thumbnailProvider = MediaThumbnailProvider.shared

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = ratio(for: isSeeking ? seekValue : currentTime)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * progress, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .offset(x: max(0, min(width - 12, width * progress - 6)))

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isSeeking {
                                    isSeeking = true
                                }
                                updatePreview(at: value.location.x, width: width)
                            }
                            .onEnded { value in
                                updatePreview(at: value.location.x, width: width)
                                onCommit(seekValue)
                                isSeeking = false
                                previewTime = nil
                                previewImage = nil
                            }
                    )

                if let previewTime {
                    previewCard(time: previewTime)
                        .position(
                            x: min(max(width * ratio(for: previewTime), 52), width - 52),
                            y: -54
                        )
                }
            }
        }
        // GeometryReader expands to the proposed height unless it is bounded.
        // Keep the scrubber compact so the surrounding control capsule does
        // not grow to fill the entire player.
        .frame(minWidth: 80, minHeight: 28, maxHeight: 28)
        .onDisappear {
            thumbnailTask?.cancel()
        }
        .opacity(duration > 0 ? 1 : 0.55)
        .allowsHitTesting(duration > 0)
    }

    private func ratio(for time: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    private func updatePreview(at x: CGFloat, width: CGFloat) {
        guard duration > 0, let url else { return }
        let time = min(max(Double(x / width) * duration, 0), duration)
        seekValue = time
        previewTime = time
        thumbnailTask?.cancel()
        thumbnailTask = Task { @MainActor in
            let image = await thumbnailProvider.image(for: url, at: time)
            guard !Task.isCancelled else { return }
            previewImage = image
        }
    }

    @ViewBuilder
    private func previewCard(time: Double) -> some View {
        VStack(spacing: 4) {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 104, height: 64)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text(timeString(time))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(5)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 7))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
