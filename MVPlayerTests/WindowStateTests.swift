import AppKit
import XCTest
@testable import MVPlayer

@MainActor
final class WindowStateTests: XCTestCase {
    func testFullscreenStateStaysActiveUntilPresenterFinishesExiting() {
        let state = WindowState()

        state.toggleFullscreen()
        XCTAssertTrue(state.isFullscreen)
        XCTAssertEqual(state.fullscreenExitRequest, 0)

        state.toggleFullscreen()
        XCTAssertTrue(state.isFullscreen)
        XCTAssertEqual(state.fullscreenExitRequest, 1)

        state.toggleFullscreen()
        XCTAssertEqual(state.fullscreenExitRequest, 1)

        state.fullscreenDidExit()
        XCTAssertFalse(state.isFullscreen)
    }

    func testFullscreenCapturesVideoSurfaceFrameInScreenCoordinates() {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 180, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let videoView = NSView(frame: NSRect(x: 35, y: 260, width: 830, height: 310))
        contentView.addSubview(videoView)
        window.contentView = contentView

        let state = WindowState()
        state.attachVideoView(videoView)
        state.toggleFullscreen()

        XCTAssertEqual(
            state.fullscreenSourceFrame,
            NSRect(x: 155, y: 440, width: 830, height: 310)
        )
    }
}
