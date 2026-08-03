import SwiftUI

struct ContentView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var windowState: WindowState

    var body: some View {
        Group {
            if let engine = appModel.engine, let videoView = appModel.videoView {
                PlayerLayout(
                    appModel: appModel,
                    engine: engine,
                    videoView: videoView,
                    windowState: windowState
                )
            } else {
                LibMPVSetupView(
                    errorMessage: appModel.startupError,
                    retry: appModel.retryLibMPV
                )
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PlayerLayout: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    let videoView: MVVideoView
    @ObservedObject var windowState: WindowState

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

            FolderBrowserView(appModel: appModel)
                .frame(minHeight: 190, idealHeight: 260)
        }
        .background(Color.black)
        .onAppear {
            windowState.attachVideoView(videoView)
        }
        .background {
            FullscreenPlayerPresenter(
                isPresented: windowState.isFullscreen,
                exitRequest: windowState.fullscreenExitRequest,
                sourceFrame: windowState.fullscreenSourceFrame
            ) {
                PlayerContainerView(
                    appModel: appModel,
                    engine: engine,
                    videoView: videoView,
                    windowState: windowState,
                    isVideoSurfaceActive: true
                )
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
            } onDismiss: {
                windowState.fullscreenDidExit()
            }
            .frame(width: 0, height: 0)
        }
    }
}
