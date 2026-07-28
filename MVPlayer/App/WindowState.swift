import AppKit
import SwiftUI

@MainActor
final class WindowState: ObservableObject {
    @Published private(set) var isFullscreen = false

    private weak var window: NSWindow?
    private var observerTokens: [NSObjectProtocol] = []

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens = []
        self.window = window
        isFullscreen = window.styleMask.contains(.fullScreen)

        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isFullscreen = true }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.isFullscreen = false }
            }
        )
    }

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }
}

struct WindowReader: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}
