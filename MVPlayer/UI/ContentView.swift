import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var windowState: WindowState
    let library: FolderLibrary

    var body: some View {
        Group {
            if let engine = appModel.engine, let videoView = appModel.videoView {
                PlayerLayout(
                    appModel: appModel,
                    engine: engine,
                    videoView: videoView,
                    windowState: windowState,
                    library: library
                )
            } else {
                LibMPVSetupView(
                    errorMessage: appModel.startupError,
                    retry: appModel.retryLibMPV
                )
            }
        }
        .preferredColorScheme(.dark)
        .background {
            ActivePlayerTracker(
                target: PlayerTarget(appModel: appModel, windowState: windowState)
            )
            .frame(width: 0, height: 0)
        }
    }
}

private struct PlayerLayout: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    let videoView: MVVideoView
    @ObservedObject var windowState: WindowState
    let library: FolderLibrary

    var body: some View {
        VSplitView {
            PlayerContainerView(
                appModel: appModel,
                engine: engine,
                videoView: videoView,
                windowState: windowState,
                isVideoSurfaceActive: !windowState.isFullscreen
            )
            .frame(minHeight: 280)

            FolderBrowserView(appModel: appModel, library: library)
                .frame(minHeight: 215, idealHeight: 285)
        }
        .background(Color.black)
        .onAppear {
            windowState.attachVideoView(videoView)
        }
        .background {
            FullscreenPlayerLayer(
                appModel: appModel,
                engine: engine,
                videoView: videoView,
                windowState: windowState,
                showsQueueControls: true
            )
        }
    }
}
