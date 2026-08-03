import XCTest
@testable import MVPlayer

@MainActor
final class PlayerStateTests: XCTestCase {
    private let video = URL(fileURLWithPath: "/tmp/mv-player-tests/A.mp4")

    func testResetForLoadClearsThePausedFlag() {
        let state = PlayerState()
        state.reset()

        state.resetForLoad(video)

        // Closing a video leaves isPaused == true while mpv itself stays
        // unpaused, so loading the next file has to clear the flag; mpv sends
        // no `pause` event when the property does not actually change.
        XCTAssertFalse(state.isPaused)
    }

    func testResetForLoadClearsPlaybackPosition() {
        let state = PlayerState()
        state.currentTime = 42
        state.duration = 120

        state.resetForLoad(video)

        XCTAssertEqual(state.currentURL, video)
        XCTAssertEqual(state.currentTime, 0)
        XCTAssertEqual(state.duration, 0)
        XCTAssertTrue(state.isLoading)
    }
}
