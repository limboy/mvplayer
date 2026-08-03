import AppKit
import CMPVShim
import OpenGL.GL3

private func mpvOpenGLGetProcAddress(
    context: UnsafeMutableRawPointer?,
    name: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let context, let name else { return nil }
    let view = Unmanaged<MVVideoView>.fromOpaque(context).takeUnretainedValue()
    guard let library = view.openGLLibrary else { return nil }
    return dlsym(library, name)
}

private func mpvRenderUpdate(context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let view = Unmanaged<MVVideoView>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        view.needsDisplay = true
    }
}

final class MVVideoView: NSOpenGLView {
    let engine: MPVPlayerEngine
    fileprivate nonisolated(unsafe) let openGLLibrary: UnsafeMutableRawPointer?
    private var rendererInitialized = false

    init(engine: MPVPlayerEngine) {
        self.engine = engine
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

        // Avoid making the user-interactive AppKit thread wait for a lower
        // QoS display-sync thread inside flushBuffer().
        var swapInterval: GLint = 0
        openGLContext.setValues(&swapInterval, for: .swapInterval)

        var error = [CChar](repeating: 0, count: 1_024)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            mvp_mpv_initialize_renderer(
                engine.rawHandle,
                mpvOpenGLGetProcAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                buffer.baseAddress,
                buffer.count
            )
        }

        guard result >= 0 else {
            let message = error.withUnsafeBufferPointer {
                String(cString: $0.baseAddress!)
            }
            Task { @MainActor [weak self] in
                self?.engine.state.errorMessage = message
            }
            return
        }

        rendererInitialized = true
        mvp_mpv_set_render_update_callback(
            engine.rawHandle,
            mpvRenderUpdate,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    override func reshape() {
        super.reshape()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rendererInitialized, let openGLContext else {
            NSColor.black.setFill()
            dirtyRect.fill()
            return
        }

        openGLContext.makeCurrentContext()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        _ = mvp_mpv_render(
            engine.rawHandle,
            framebuffer,
            Int32(width),
            Int32(height),
            true
        )
        openGLContext.flushBuffer()
        mvp_mpv_report_swap(engine.rawHandle)
    }

    func detachRenderer() {
        guard rendererInitialized else { return }
        openGLContext?.makeCurrentContext()
        mvp_mpv_set_render_update_callback(engine.rawHandle, nil, nil)
        mvp_mpv_destroy_renderer(engine.rawHandle)
        rendererInitialized = false
        NSOpenGLContext.clearCurrentContext()
    }

}
