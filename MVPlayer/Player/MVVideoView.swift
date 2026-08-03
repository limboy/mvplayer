import AppKit
import CMPVShim
import OpenGL.GL3

private func mpvOpenGLGetProcAddress(
    context: UnsafeMutableRawPointer?,
    name: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let name,
          let view = MPVCallbackContext<MVVideoView>.target(of: context),
          let library = view.openGLLibrary
    else {
        return nil
    }
    return dlsym(library, name)
}

private func mpvRenderUpdate(context: UnsafeMutableRawPointer?) {
    MPVCallbackContext<MVVideoView>.target(of: context)?.requestDisplay()
}

private final class MVOpenGLRenderWorker: @unchecked Sendable {
    private let engine: MPVPlayerEngine
    private let queue = DispatchQueue(
        label: "me.limboy.mvplayer.opengl-render",
        qos: .default
    )
    private let stateLock = NSLock()
    private var context: NSOpenGLContext?
    private var isActive = false
    private var isVideoRenderingEnabled = false
    private var pendingSize: (width: Int, height: Int)?
    private var renderScheduled = false

    init(engine: MPVPlayerEngine) {
        self.engine = engine
    }

    func activate(context: NSOpenGLContext) {
        stateLock.withLock {
            self.context = context
            isActive = true
        }
    }

    func enqueue(width: Int, height: Int) {
        let shouldSchedule = stateLock.withLock {
            guard isActive, isVideoRenderingEnabled else { return false }

            // During a window animation AppKit can request draws faster than the
            // OpenGL surface can be resized and rendered. Keep only the newest
            // size instead of building a queue of already-obsolete frames.
            pendingSize = (width, height)
            guard !renderScheduled else { return false }
            renderScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        queue.async { [weak self] in
            self?.drainPendingRenders()
        }
    }

    func setVideoRenderingEnabled(_ enabled: Bool) {
        stateLock.withLock {
            isVideoRenderingEnabled = enabled
            if !enabled {
                pendingSize = nil
            }
        }
        if !enabled {
            queue.async { [weak self] in
                self?.clearSurface()
            }
        }
    }

    func deactivate() {
        stateLock.withLock {
            isActive = false
            pendingSize = nil
        }
        // Synchronous on purpose: the caller shuts the engine down as soon as
        // this returns, and mvp_mpv_destroy frees the render context too. A
        // render already in flight has to finish, and this one has to run,
        // before the handle goes away. Nothing on this queue waits on the main
        // thread, so blocking here cannot deadlock.
        queue.sync { [self] in
            guard let context = stateLock.withLock({ self.context }) else { return }
            context.lock()
            context.makeCurrentContext()
            mvp_mpv_destroy_renderer(engine.rawHandle)
            NSOpenGLContext.clearCurrentContext()
            context.unlock()
            stateLock.withLock {
                self.context = nil
            }
        }
    }

    private func render(width: Int, height: Int) {
        guard let context = stateLock.withLock({
            isActive && isVideoRenderingEnabled ? self.context : nil
        }) else { return }

        context.lock()
        defer { context.unlock() }
        context.makeCurrentContext()
        defer { NSOpenGLContext.clearCurrentContext() }
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        _ = mvp_mpv_render(
            engine.rawHandle,
            framebuffer,
            Int32(width),
            Int32(height),
            true
        )
        context.flushBuffer()
        mvp_mpv_report_swap(engine.rawHandle)
    }

    private func drainPendingRenders() {
        while true {
            let size = stateLock.withLock { () -> (width: Int, height: Int)? in
                guard isActive, isVideoRenderingEnabled else {
                    pendingSize = nil
                    renderScheduled = false
                    return nil
                }
                guard let pendingSize else {
                    renderScheduled = false
                    return nil
                }
                self.pendingSize = nil
                return pendingSize
            }
            guard let size else { return }
            render(width: size.width, height: size.height)
        }
    }

    private func clearSurface() {
        guard let context = stateLock.withLock({
            isActive && !isVideoRenderingEnabled ? self.context : nil
        }) else { return }

        context.lock()
        defer { context.unlock() }
        context.makeCurrentContext()
        defer { NSOpenGLContext.clearCurrentContext() }
        glDisable(GLenum(GL_SCISSOR_TEST))
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        context.flushBuffer()
    }
}

final class MVVideoView: NSOpenGLView {
    let engine: MPVPlayerEngine
    fileprivate nonisolated(unsafe) let openGLLibrary: UnsafeMutableRawPointer?
    private let renderWorker: MVOpenGLRenderWorker
    private var rendererInitialized = false
    private nonisolated let displayRequestLock = NSLock()
    private nonisolated(unsafe) var displayRequestPending = false

    /// Owned by the render context and by mpv respectively, until
    /// `detachRenderer` tears both down. A view released without that call
    /// leaks two boxes, which is the deliberate trade: the alternative is mpv
    /// holding a pointer to freed memory.
    private var procAddressContext: UnsafeMutableRawPointer?
    private var renderUpdateContext: UnsafeMutableRawPointer?

    init(engine: MPVPlayerEngine) {
        self.engine = engine
        renderWorker = MVOpenGLRenderWorker(engine: engine)
        openGLLibrary = dlopen(
            "/System/Library/Frameworks/OpenGL.framework/OpenGL",
            RTLD_LAZY | RTLD_LOCAL
        )

        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile),
            UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAColorSize),
            24,
            UInt32(NSOpenGLPFAAlphaSize),
            8,
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            0
        ]
        let format = NSOpenGLPixelFormat(attributes: attributes)!
        super.init(frame: .zero, pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard !rendererInitialized else { return }
        guard let openGLContext else { return }
        openGLContext.makeCurrentContext()

        // Do not add a vertical-refresh wait on top of libmpv's frame timing.
        // Buffer presentation itself runs on renderWorker's default-QoS queue.
        var swapInterval: GLint = 0
        openGLContext.setValues(&swapInterval, for: .swapInterval)

        // mpv keeps this for as long as the render context lives, not just for
        // the length of the call below.
        let procAddressContext = MPVCallbackContext<MVVideoView>.passRetained(self)
        var error = [CChar](repeating: 0, count: 1_024)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            mvp_mpv_initialize_renderer(
                engine.rawHandle,
                mpvOpenGLGetProcAddress,
                procAddressContext,
                buffer.baseAddress,
                buffer.count
            )
        }

        guard result >= 0 else {
            MPVCallbackContext<MVVideoView>.release(procAddressContext)
            let message = error.withUnsafeBufferPointer {
                String(cString: $0.baseAddress!)
            }
            Task { @MainActor [weak self] in
                self?.engine.state.errorMessage = message
            }
            return
        }

        self.procAddressContext = procAddressContext
        rendererInitialized = true
        renderWorker.activate(context: openGLContext)
        let renderUpdateContext = MPVCallbackContext<MVVideoView>.passRetained(self)
        self.renderUpdateContext = renderUpdateContext
        mvp_mpv_set_render_update_callback(
            engine.rawHandle,
            mpvRenderUpdate,
            renderUpdateContext
        )
    }

    override func reshape() {
        guard let openGLContext else {
            super.reshape()
            needsDisplay = true
            return
        }
        openGLContext.lock()
        super.reshape()
        openGLContext.unlock()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rendererInitialized, openGLContext != nil else {
            NSColor.black.setFill()
            dirtyRect.fill()
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        renderWorker.enqueue(width: width, height: height)
    }

    fileprivate nonisolated func requestDisplay() {
        let shouldSchedule = displayRequestLock.withLock {
            guard !displayRequestPending else { return false }
            displayRequestPending = true
            return true
        }
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayRequestLock.withLock {
                self.displayRequestPending = false
            }
            self.needsDisplay = true
        }
    }

    func setVideoRenderingEnabled(_ enabled: Bool) {
        renderWorker.setVideoRenderingEnabled(enabled)
        if enabled {
            needsDisplay = true
        }
    }

    func detachRenderer() {
        guard rendererInitialized else { return }
        mvp_mpv_set_render_update_callback(engine.rawHandle, nil, nil)
        rendererInitialized = false
        // Returns once the render context is destroyed, which is the point
        // after which neither callback can be entered again and the boxes
        // holding this view can be let go.
        renderWorker.deactivate()
        MPVCallbackContext<MVVideoView>.release(renderUpdateContext)
        renderUpdateContext = nil
        MPVCallbackContext<MVVideoView>.release(procAddressContext)
        procAddressContext = nil
    }

}
