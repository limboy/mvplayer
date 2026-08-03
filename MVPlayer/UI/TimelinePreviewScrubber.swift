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
    @State private var committedSeekTarget: Double?
    @State private var seekCompletionTask: Task<Void, Never>?

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
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard !isSeeking else { return }
                            updatePreview(
                                at: location.x,
                                width: width,
                                updatesSeekValue: false
                            )
                        case .ended:
                            clearPreview()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if committedSeekTarget != nil {
                                    seekCompletionTask?.cancel()
                                    committedSeekTarget = nil
                                }
                                updatePreview(at: value.location.x, width: width)
                                if !isSeeking {
                                    isSeeking = true
                                }
                            }
                            .onEnded { value in
                                let destination = updatePreview(
                                    at: value.location.x,
                                    width: width
                                ) ?? seekValue
                                committedSeekTarget = destination
                                onCommit(destination)
                                scheduleSeekCompletionFallback()
                                clearPreview()
                            }
                    )

                if let previewTime {
                    previewCard(time: previewTime)
                        .position(
                            x: min(max(width * ratio(for: previewTime), 52), width - 52),
                            y: -54
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        // GeometryReader expands to the proposed height unless it is bounded.
        // Keep the scrubber compact so the surrounding control capsule does
        // not grow to fill the entire player.
        .frame(minWidth: 80, minHeight: 28, maxHeight: 28)
        .onDisappear {
            clearPreview()
            seekCompletionTask?.cancel()
        }
        .onChange(of: url) { _, _ in
            clearPreview()
        }
        .onChange(of: duration) { _, _ in
            clearPreview()
        }
        .onChange(of: currentTime) { _, newTime in
            guard let target = committedSeekTarget else { return }
            guard abs(newTime - target) <= 0.5 else { return }
            finishCommittedSeek()
        }
        .opacity(duration > 0 ? 1 : 0.55)
        .allowsHitTesting(duration > 0)
    }

    private func ratio(for time: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    @discardableResult
    private func updatePreview(
        at x: CGFloat,
        width: CGFloat,
        updatesSeekValue: Bool = true
    ) -> Double? {
        guard duration > 0, let url else { return nil }
        let time = min(max(Double(x / width) * duration, 0), duration)
        if updatesSeekValue {
            seekValue = time
        }
        previewTime = time
        thumbnailTask?.cancel()
        thumbnailTask = Task { @MainActor in
            let image = await thumbnailProvider.image(for: url, at: time)
            guard !Task.isCancelled else { return }
            previewImage = image
        }
        return time
    }

    private func clearPreview() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        previewTime = nil
        previewImage = nil
    }

    private func scheduleSeekCompletionFallback() {
        seekCompletionTask?.cancel()
        seekCompletionTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            finishCommittedSeek()
        }
    }

    private func finishCommittedSeek() {
        seekCompletionTask?.cancel()
        seekCompletionTask = nil
        committedSeekTarget = nil
        isSeeking = false
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
