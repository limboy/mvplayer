import AppKit
import SwiftUI

@MainActor
final class WindowState: ObservableObject {
    @Published private(set) var isFullscreen = false
    @Published private(set) var isFullscreenContentPresented = false
    @Published private(set) var fullscreenExitRequest: UInt = 0
    @Published private(set) var fullscreenReturnRequest: UInt = 0
    @Published private(set) var fullscreenSourceFrame: NSRect?

    private var isExitRequested = false
    private weak var videoView: NSView?

    func attachVideoView(_ videoView: NSView) {
        self.videoView = videoView
    }

    func toggleFullscreen() {
        if isFullscreen {
            guard !isExitRequested else { return }
            isExitRequested = true
            isFullscreenContentPresented = false
            fullscreenExitRequest &+= 1
        } else {
            isExitRequested = false
            fullscreenSourceFrame = videoView.flatMap(Self.screenFrame)
            isFullscreen = true
        }
    }

    func fullscreenDidEnter() {
        guard !isExitRequested else { return }
        isFullscreenContentPresented = true
    }

    func returnVideoFromFullscreen() {
        guard isFullscreen, !isExitRequested else { return }
        isExitRequested = true
        isFullscreenContentPresented = false
        fullscreenReturnRequest &+= 1
    }

    func fullscreenWillExit() {
        isExitRequested = true
        isFullscreenContentPresented = false
    }

    func fullscreenDidExit() {
        isExitRequested = false
        isFullscreenContentPresented = false
        isFullscreen = false
        fullscreenSourceFrame = nil
    }

    private static func screenFrame(for view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        view.layoutSubtreeIfNeeded()
        let frameInWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}
