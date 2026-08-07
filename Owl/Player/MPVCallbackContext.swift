import Foundation

/// A heap box handed to libmpv as a callback context.
///
/// libmpv calls back from its own threads, at moments the app does not choose.
/// Passing the object those callbacks want as an unretained pointer leaves a
/// window where one already in flight resolves a pointer whose target is
/// halfway through being deallocated. Retaining the object instead would make
/// it immortal, because the only place its callbacks get cleared is its own
/// deinit.
///
/// The box carries the reference count on libmpv's behalf, so the pointer stays
/// valid for as long as libmpv might use it, and the weak reference inside it
/// reads as nil once the target is gone. Upgrading that reference is atomic:
/// either the callback gets a target that is guaranteed to outlive the call, or
/// it gets nothing.
///
/// A pointer from `passRetained` has to be handed back to `release` once
/// libmpv can no longer reach it — after `mvp_mpv_destroy` for the player, and
/// after `mvp_mpv_destroy_renderer` for the render context. Leaking a box
/// costs a few bytes; releasing one while libmpv still holds the pointer is a
/// dangling context, which is the thing this exists to prevent.
final class MPVCallbackContext<Target: AnyObject> {
    private weak var target: Target?

    private init(target: Target) {
        self.target = target
    }

    static func passRetained(_ target: Target) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(MPVCallbackContext(target: target)).toOpaque()
    }

    /// The object the callback was registered for, or nil once it has been
    /// deallocated and the callback has nothing left to do.
    static func target(of context: UnsafeMutableRawPointer?) -> Target? {
        guard let context else { return nil }
        return unmanaged(context).takeUnretainedValue().target
    }

    static func release(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        unmanaged(context).release()
    }

    private static func unmanaged(
        _ context: UnsafeMutableRawPointer
    ) -> Unmanaged<MPVCallbackContext<Target>> {
        Unmanaged<MPVCallbackContext<Target>>.fromOpaque(context)
    }
}
