import SwiftUI

@main
struct MVPlayerApp: App {
    @StateObject private var appModel: AppModel
    @StateObject private var windowState = WindowState()

    init() {
        _appModel = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("MV Player") {
            ContentView(appModel: appModel, windowState: windowState)
                .frame(minWidth: 760, minHeight: 560)
                .background(
                    WindowReader { window in
                        windowState.attach(window)
                    }
                    .frame(width: 0, height: 0)
                )
        }
        .defaultSize(width: 1_080, height: 760)
        .commands {
            PlaybackCommands(appModel: appModel, windowState: windowState)
        }
    }
}

struct PlaybackCommands: Commands {
    @ObservedObject var appModel: AppModel
    @ObservedObject var windowState: WindowState

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause") {
                appModel.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Seek Backward 5 Seconds") {
                appModel.seek(by: -5)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Seek Forward 5 Seconds") {
                appModel.seek(by: 5)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button("Volume Up") {
                appModel.changeVolume(by: 5)
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Button("Volume Down") {
                appModel.changeVolume(by: -5)
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            Divider()

            Button("Toggle Full Screen") {
                windowState.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [])

            Button("Toggle Full Screen (System)") {
                windowState.toggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
    }
}
