import SwiftUI

struct VideoSurface: NSViewRepresentable {
    let view: MVVideoView

    func makeNSView(context: Context) -> MVVideoView {
        view
    }

    func updateNSView(_ nsView: MVVideoView, context: Context) {
        nsView.needsDisplay = true
    }
}
