import AppKit

extension NSOpenPanel {
    /// Presents the panel as a sheet and calls `completion` with what was
    /// chosen, or not at all if the panel was cancelled.
    ///
    /// Never `runModal()`. That spins a modal run loop on the main thread for as
    /// long as the panel is up, and the main thread is where the video view's
    /// draws are asked for, so the picture behind the panel stops moving until
    /// the user is done choosing. A sheet leaves the run loop alone, and it also
    /// attaches the panel to the window it came from rather than floating it
    /// over whichever window happens to be in front.
    func presentAsSheet(completion: @escaping ([URL]) -> Void) {
        let handler = { (response: NSApplication.ModalResponse) in
            guard response == .OK else { return }
            completion(self.urls)
        }

        // In full screen the key window is the full screen player, which is
        // where the sheet belongs. Without any window at all — nothing on
        // screen has focus yet — the panel opens on its own instead.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            beginSheetModal(for: window, completionHandler: handler)
        } else {
            begin(completionHandler: handler)
        }
    }
}
