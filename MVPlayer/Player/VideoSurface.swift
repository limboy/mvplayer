import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let view: MVVideoView
    let isActive: Bool

    init(view: MVVideoView, isActive: Bool = true) {
        self.view = view
        self.isActive = isActive
    }

    func makeNSView(context: Context) -> VideoSurfaceHostView {
        VideoSurfaceHostView()
    }

    func updateNSView(_ nsView: VideoSurfaceHostView, context: Context) {
        guard isActive else { return }
        nsView.attach(view)
    }
}

final class VideoSurfaceHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ videoView: MVVideoView) {
        if videoView.superview !== self {
            videoView.removeFromSuperview()
            videoView.frame = bounds
            videoView.autoresizingMask = [.width, .height]
            addSubview(videoView)
        }

        videoView.frame = bounds
        videoView.needsDisplay = true
    }
}
