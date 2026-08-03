import XCTest
@testable import MVPlayer

final class MPVCallbackContextTests: XCTestCase {
    private final class Target {}

    func testALiveTargetResolvesThroughTheContextPointer() {
        let target = Target()
        let context = MPVCallbackContext<Target>.passRetained(target)
        defer { MPVCallbackContext<Target>.release(context) }

        XCTAssertTrue(MPVCallbackContext<Target>.target(of: context) === target)
    }

    func testTheContextDoesNotKeepItsTargetAlive() {
        var target: Target? = Target()
        weak var observedTarget = target
        let context = MPVCallbackContext<Target>.passRetained(target!)
        defer { MPVCallbackContext<Target>.release(context) }

        target = nil

        // The box outlives its target on libmpv's behalf: the pointer stays
        // valid, so a callback arriving after the target is gone reads nothing
        // instead of dereferencing freed memory. Holding the target strongly
        // would work too, but nothing would ever release it — the callbacks are
        // only cleared from the target's own deinit.
        XCTAssertNil(observedTarget)
        XCTAssertNil(MPVCallbackContext<Target>.target(of: context))
    }

    func testAMissingContextResolvesToNothing() {
        XCTAssertNil(MPVCallbackContext<Target>.target(of: nil))
    }
}
