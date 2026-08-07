import AppKit
import SwiftUI

/// Persists the host window's size and position under a stable key.
///
/// SwiftUI autosaves window frames under a key derived from the root view's
/// type name, so editing the view hierarchy silently invalidates the stored
/// frame and the window falls back to `defaultSize`. This keeps the frame under
/// a fixed key instead.
struct WindowFrameAutosave: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        WindowFrameAutosaver.install(key: key, on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        WindowFrameAutosaver.install(key: key, on: nsView)
    }
}

/// Restores a window's frame once and writes it back whenever it changes.
///
/// The frame is read and written directly rather than through
/// `NSWindow.saveFrame(usingName:)`: SwiftUI claims the window's
/// `frameAutosaveName` for its own key while setting the window up, and AppKit
/// then discards frames saved under any other name. The autosaver is owned by a
/// registry keyed on the window so that saving keeps working no matter when
/// SwiftUI discards the representable's view.
@MainActor
final class WindowFrameAutosaver {
    private static var autosavers: [ObjectIdentifier: WindowFrameAutosaver] = [:]

    static func install(key: String, on view: NSView) {
        guard let window = view.window else {
            // The view has no window during the first layout pass.
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                install(key: key, on: view)
            }
            return
        }

        let identifier = ObjectIdentifier(window)
        guard autosavers[identifier] == nil else { return }
        autosavers[identifier] = WindowFrameAutosaver(window: window, key: key)
    }

    private let key: String
    private unowned let window: NSWindow
    private var observers: [NSObjectProtocol] = []

    private init(window: NSWindow, key: String) {
        self.window = window
        self.key = key

        restore()
        observe()
    }

    private func restore() {
        guard let saved = UserDefaults.standard.string(forKey: key) else { return }

        let frame = NSRectFromString(saved)
        guard frame.width > 0, frame.height > 0 else { return }

        // A frame saved on a display that is gone can land the window out of
        // reach; pull it back onto a visible screen.
        let onVisibleScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        let screen = window.screen ?? NSScreen.main
        let restored = onVisibleScreen || screen == nil
            ? frame
            : window.constrainFrameRect(frame, to: screen)

        window.setFrame(restored, display: false)
    }

    private func observe() {
        let center = NotificationCenter.default
        let windowEvents: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.willCloseNotification
        ]

        observers = windowEvents.map { event in
            center.addObserver(forName: event, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.save()
                    if event == NSWindow.willCloseNotification {
                        self?.detach()
                    }
                }
            }
        }

        // Quitting closes the window without always reporting a frame change.
        observers.append(
            center.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            }
        )
    }

    private func save() {
        // A fullscreen or minimized frame is not what should come back on the
        // next launch.
        guard !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }

        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }

    private func detach() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
        Self.autosavers[ObjectIdentifier(window)] = nil
    }
}
