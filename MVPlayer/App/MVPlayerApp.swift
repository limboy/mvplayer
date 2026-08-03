import SwiftUI

@main
struct MVPlayerApp: App {
    @StateObject private var appModel: AppModel
    @StateObject private var windowState = WindowState()

    init() {
        _appModel = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("MVPlayer") {
            ContentView(appModel: appModel, windowState: windowState)
                .frame(minWidth: 560, minHeight: 560)
                .background {
                    WindowFrameAutosave(key: "MainWindowFrame")
                        .frame(width: 0, height: 0)
                }
        }
        .defaultSize(width: 1_080, height: 760)
        .commands {
            PlaybackCommands(appModel: appModel, windowState: windowState)
        }
    }
}

/// The Playback menu.
///
/// Only full screen carries a key equivalent, and it is the system one. The
/// space bar, the arrows and a bare `f` all work too, but they are watched by
/// `PlayerKeyboardMonitor` instead of being bound here: a menu equivalent is
/// matched before the key event reaches the window, so binding an unmodified
/// key in the menu takes it away from every view in the app for good.
struct PlaybackCommands: Commands {
    @ObservedObject var appModel: AppModel
    @ObservedObject var windowState: WindowState

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause") {
                appModel.togglePlayPause()
            }

            Button("Seek Backward 5 Seconds") {
                appModel.seek(by: -5)
            }

            Button("Seek Forward 5 Seconds") {
                appModel.seek(by: 5)
            }

            Button("Volume Up") {
                appModel.changeVolume(by: 5)
            }

            Button("Volume Down") {
                appModel.changeVolume(by: -5)
            }

            Divider()

            Button(windowState.isFullscreen ? "Exit Full Screen" : "Enter Full Screen") {
                windowState.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
    }
}
