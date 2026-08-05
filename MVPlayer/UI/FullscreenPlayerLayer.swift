import SwiftUI

/// The window the player moves into for full screen, held in the background of
/// whichever layout it was opened from.
///
/// Both kinds of player window present the same picture the same way, and the
/// video view is handed over rather than copied: there is one of it, and it is
/// wherever it is being watched.
struct FullscreenPlayerLayer: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    let videoView: MVVideoView
    @ObservedObject var windowState: WindowState
    let showsQueueControls: Bool

    var body: some View {
        FullscreenPlayerPresenter(
            isPresented: windowState.isFullscreen,
            exitRequest: windowState.fullscreenExitRequest,
            returnRequest: windowState.fullscreenReturnRequest,
            sourceFrame: windowState.fullscreenSourceFrame
        ) {
            PlayerContainerView(
                appModel: appModel,
                engine: engine,
                videoView: videoView,
                windowState: windowState,
                isVideoSurfaceActive: true,
                showsQueueControls: showsQueueControls
            )
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
        } onPresent: {
            windowState.fullscreenDidEnter()
        } onWillDismiss: {
            windowState.fullscreenWillExit()
        } onDismiss: {
            windowState.fullscreenDidExit()
        }
        .frame(width: 0, height: 0)
    }
}
