import AppKit
import SwiftUI

struct FullscreenPlayerPresenter<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let exitRequest: UInt
    let sourceFrame: NSRect?
    let content: Content
    let onDismiss: @MainActor () -> Void

    init(
        isPresented: Bool,
        exitRequest: UInt,
        sourceFrame: NSRect?,
        @ViewBuilder content: () -> Content,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.isPresented = isPresented
        self.exitRequest = exitRequest
        self.sourceFrame = sourceFrame
        self.content = content()
        self.onDismiss = onDismiss
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            anchorView: nsView,
            isPresented: isPresented,
            exitRequest: exitRequest,
            sourceFrame: sourceFrame,
            content: content
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.closeImmediately()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private let onDismiss: @MainActor () -> Void
        private var fullscreenWindow: NSWindow?
        private var hostingController: NSHostingController<Content>?
        private var lastExitRequest: UInt = 0
        private var presentationScheduled = false
        private var hasEnteredFullscreen = false
        private var exitWhenEntered = false
        private var isClosing = false
        private var windowedFrame: NSRect?

        init(onDismiss: @escaping @MainActor () -> Void) {
            self.onDismiss = onDismiss
        }

        func update(
            anchorView: NSView,
            isPresented: Bool,
            exitRequest: UInt,
            sourceFrame: NSRect?,
            content: Content
        ) {
            if isClosing, !isPresented {
                finalizeClose()
                return
            }

            hostingController?.rootView = content

            if isPresented, fullscreenWindow == nil, !presentationScheduled {
                lastExitRequest = exitRequest
                presentationScheduled = true
                let sourceWindow = anchorView.window

                // Give SwiftUI one update cycle to mark the normal surface host
                // inactive before the fullscreen host takes ownership of the view.
                DispatchQueue.main.async { [weak self] in
                    self?.present(
                        content: content,
                        sourceFrame: sourceFrame,
                        sourceWindow: sourceWindow
                    )
                }
                return
            }

            guard isPresented else {
                if fullscreenWindow != nil {
                    requestExit()
                }
                return
            }

            if exitRequest != lastExitRequest {
                lastExitRequest = exitRequest
                requestExit()
            }
        }

        private func present(
            content: Content,
            sourceFrame: NSRect?,
            sourceWindow: NSWindow?
        ) {
            presentationScheduled = false
            guard fullscreenWindow == nil else { return }

            let initialFrame = sourceFrame
                ?? sourceWindow?.contentView.flatMap { contentView in
                    sourceWindow?.convertToScreen(contentView.bounds)
                }
                ?? sourceWindow?.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1_280, height: 720)

            let hostingController = NSHostingController(rootView: content)
            let window = NSWindow(
                contentRect: initialFrame,
                styleMask: [.titled, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "MV Player"
            window.collectionBehavior = [.fullScreenPrimary]
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isMovable = false
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentViewController = hostingController
            window.delegate = self
            window.setFrame(initialFrame, display: false)
            hostingController.view.frame = NSRect(origin: .zero, size: initialFrame.size)
            hostingController.view.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            self.hostingController = hostingController
            fullscreenWindow = window
            windowedFrame = initialFrame
            hasEnteredFullscreen = false
            exitWhenEntered = false
            isClosing = false

            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
        }

        private func requestExit() {
            guard let fullscreenWindow, !isClosing else { return }
            guard hasEnteredFullscreen else {
                exitWhenEntered = true
                return
            }
            fullscreenWindow.toggleFullScreen(nil)
        }

        func customWindowsToEnterFullScreen(
            for window: NSWindow,
            on screen: NSScreen
        ) -> [NSWindow]? {
            guard window === fullscreenWindow else { return nil }
            return [window]
        }

        func window(
            _ window: NSWindow,
            startCustomAnimationToEnterFullScreenOn screen: NSScreen,
            withDuration duration: TimeInterval
        ) {
            guard window === fullscreenWindow else { return }
            animate(window, to: screen.frame, duration: duration)
        }

        func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
            guard window === fullscreenWindow else { return nil }
            return [window]
        }

        func window(
            _ window: NSWindow,
            startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval
        ) {
            guard window === fullscreenWindow, let windowedFrame else { return }
            animate(window, to: windowedFrame, duration: duration)
        }

        private func animate(
            _ window: NSWindow,
            to frame: NSRect,
            duration: TimeInterval
        ) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
            }
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            guard notification.object as? NSWindow === fullscreenWindow else { return }
            hasEnteredFullscreen = true
            if exitWhenEntered {
                exitWhenEntered = false
                requestExit()
            }
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            guard notification.object as? NSWindow === fullscreenWindow else { return }
            finishClosing(notify: true)
        }

        func windowDidFailToEnterFullScreen(_ window: NSWindow) {
            guard window === fullscreenWindow else { return }
            finishClosing(notify: true)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard sender === fullscreenWindow else { return true }
            requestExit()
            return false
        }

        func closeImmediately() {
            finishClosing(notify: false)
        }

        private func finishClosing(notify: Bool) {
            guard !isClosing else { return }
            isClosing = true

            hasEnteredFullscreen = false
            exitWhenEntered = false

            if notify {
                // The normal and fullscreen players keep separate, stable host
                // views. Publishing the dismissal moves the shared video view
                // directly back to the already-laid-out normal host. The next
                // representable update closes this window in the same render pass.
                onDismiss()
            } else {
                finalizeClose()
            }
        }

        private func finalizeClose() {
            let window = fullscreenWindow
            window?.delegate = nil
            window?.contentViewController = nil
            window?.orderOut(nil)
            window?.close()

            fullscreenWindow = nil
            hostingController = nil
            windowedFrame = nil
            isClosing = false
        }
    }
}
