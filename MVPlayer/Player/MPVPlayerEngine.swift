import CMPVShim
import Foundation

private func swiftString<T>(from tuple: inout T) -> String {
    withUnsafePointer(to: &tuple) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}

private func mpvWakeupCallback(context: UnsafeMutableRawPointer?) {
    MPVCallbackContext<MPVPlayerEngine>.target(of: context)?.scheduleEventDrain()
}

final class MPVPlayerEngine: @unchecked Sendable {
    let info: LibMPVInfo
    let state: PlayerState

    var onPlaybackEnded: (@MainActor () -> Void)?
    var onFileLoaded: (@MainActor () -> Void)?

    private let handle: OpaquePointer

    /// Serializes every use of `handle` against the destroy. Reaching mpv from
    /// anywhere else has to hop through here first.
    ///
    /// A lock around the calls instead would deadlock. mpv runs the wakeup
    /// callback while holding its own client lock, so a lock taken there is
    /// taken beneath mpv's; a caller holding that same lock while it waits to
    /// enter mpv closes the cycle. Ordering the work on a serial queue needs no
    /// lock on either side.
    private let eventQueue = DispatchQueue(label: "com.example.MVPlayer.mpv-events")

    /// Whether the handle has been freed. Read and written on `eventQueue`
    /// only, and kept in a box because `shutdown` runs from deinit, where the
    /// engine itself cannot be captured.
    private final class Lifetime {
        var isDestroyed = false
    }
    private let lifetime = Lifetime()

    /// Guards the once-only part of `shutdown`. Deliberately never held while
    /// calling mpv, and never taken from an mpv callback.
    private let shutdownLock = NSLock()
    private var isShuttingDown = false

    /// Owned by libmpv until the player is destroyed. Touched only by `init`
    /// and `shutdown`, which runs at most once.
    private var wakeupContext: UnsafeMutableRawPointer?

    init(state: PlayerState) throws {
        switch LibMPVLoader.createPlayer() {
        case .success(let result):
            handle = result.0
            info = result.1
            self.state = state
        case .failure(let error):
            throw error
        }

        let wakeupContext = MPVCallbackContext<MPVPlayerEngine>.passRetained(self)
        self.wakeupContext = wakeupContext
        mvp_mpv_set_wakeup_callback(handle, mpvWakeupCallback, wakeupContext)
        scheduleEventDrain()
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        let wasShuttingDown = shutdownLock.withLock {
            let previous = isShuttingDown
            isShuttingDown = true
            return previous
        }
        guard !wasShuttingDown else { return }

        // The lock is already released, so this call cannot be part of a cycle
        // with mpv's own. Nothing has destroyed the handle at this point: the
        // only destroy is the one enqueued below, and the guard above lets that
        // happen once.
        mvp_mpv_set_wakeup_callback(handle, nil, nil)

        // Freeing on the event queue puts the destroy behind every drain and
        // command already queued. It has to be asynchronous, because deinit
        // calls this and deinit itself lands on the event queue whenever a
        // drain drops the last reference to the engine. Only values are
        // captured, never self, which deinit could not offer anyway.
        let handle = self.handle
        let lifetime = self.lifetime
        let wakeupContext = self.wakeupContext
        self.wakeupContext = nil
        eventQueue.async {
            guard !lifetime.isDestroyed else { return }
            lifetime.isDestroyed = true
            mvp_mpv_destroy(handle)
            // Clearing the callback does not stop one already running, so the
            // box outlives the engine and reads as nil for it. mpv makes no
            // further calls once the player is destroyed, which is the first
            // moment the box can go.
            MPVCallbackContext<MPVPlayerEngine>.release(wakeupContext)
        }
    }

    /// Called from mpv's wakeup callback, which runs with mpv's client lock
    /// held. Enqueuing is the only thing it may do: taking any lock here would
    /// order that lock beneath mpv's and deadlock against a thread waiting to
    /// enter mpv.
    func scheduleEventDrain() {
        eventQueue.async { [weak self] in
            self?.drainEvents()
        }
    }

    /// Hands `body` the live handle on the event queue, or drops it once the
    /// handle has been freed. Safe to call from the event queue itself, where
    /// it simply defers the work to the next block.
    private func onEventQueue(_ body: @escaping (OpaquePointer) -> Void) {
        let handle = self.handle
        let lifetime = self.lifetime
        eventQueue.async {
            guard !lifetime.isDestroyed else { return }
            body(handle)
        }
    }

    private func drainEvents() {
        guard !lifetime.isDestroyed else { return }
        while true {
            var event = MVPMPVEvent()
            guard mvp_mpv_poll_event(handle, &event) != 0 else {
                break
            }
            handle(event)
        }
    }

    private func handle(_ event: MVPMPVEvent) {
        switch event.type {
        case MVP_MPV_EVENT_PROPERTY:
            var mutableEvent = event
            let name = swiftString(from: &mutableEvent.name)
            let valueType = event.value_type
            let flag = event.flag_value != 0
            let number = event.double_value
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch name {
                case "pause" where valueType == MVP_MPV_VALUE_FLAG:
                    state.isPaused = flag
                case "time-pos" where valueType == MVP_MPV_VALUE_DOUBLE:
                    state.currentTime = number.isFinite ? max(0, number) : 0
                case "duration" where valueType == MVP_MPV_VALUE_DOUBLE:
                    state.duration = number.isFinite ? max(0, number) : 0
                case "volume" where valueType == MVP_MPV_VALUE_DOUBLE:
                    state.volume = min(max(number, 0), 100)
                case "mute" where valueType == MVP_MPV_VALUE_FLAG:
                    state.isMuted = flag
                default:
                    break
                }
            }

        case MVP_MPV_EVENT_FILE_LOADED:
            refreshTracks(selectFirstSubtitle: true)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.isLoading = false
                self.onFileLoaded?()
            }

        case MVP_MPV_EVENT_TRACKS_CHANGED:
            refreshTracks()

        case MVP_MPV_EVENT_END_FILE:
            let reason = event.end_reason
            let errorCode = event.error
            if reason == 0 {
                Task { @MainActor [weak self] in
                    self?.onPlaybackEnded?()
                }
            } else if reason == 4 {
                let message = "Playback failed (mpv error \(errorCode))."
                Task { @MainActor [weak self] in
                    self?.state.isLoading = false
                    self?.state.errorMessage = message
                }
            }

        case MVP_MPV_EVENT_COMMAND_ERROR:
            var mutableEvent = event
            let detail = swiftString(from: &mutableEvent.string_value)
            Task { @MainActor [weak self] in
                self?.state.isLoading = false
                self?.state.errorMessage = detail.isEmpty ? "The mpv command failed." : detail
            }

        case MVP_MPV_EVENT_SHUTDOWN:
            Task { @MainActor [weak self] in
                self?.state.errorMessage = "libmpv shut down unexpectedly."
            }

        default:
            break
        }
    }

    private func refreshTracks(selectFirstSubtitle: Bool = false) {
        let count = mvp_mpv_copy_subtitle_tracks(handle, nil, 0)
        let audioCount = mvp_mpv_copy_audio_tracks(handle, nil, 0)
        guard count >= 0, audioCount >= 0 else { return }

        var subtitleValues = [MVPMPVSubtitleTrack](
            repeating: MVPMPVSubtitleTrack(),
            count: Int(count)
        )
        let copiedSubtitles = subtitleValues.withUnsafeMutableBufferPointer { buffer in
            mvp_mpv_copy_subtitle_tracks(handle, buffer.baseAddress, Int32(buffer.count))
        }
        guard copiedSubtitles >= 0 else { return }

        var audioValues = [MVPMPVAudioTrack](
            repeating: MVPMPVAudioTrack(),
            count: Int(audioCount)
        )
        let copiedAudio = audioValues.withUnsafeMutableBufferPointer { buffer in
            mvp_mpv_copy_audio_tracks(handle, buffer.baseAddress, Int32(buffer.count))
        }
        guard copiedAudio >= 0 else { return }

        var subtitles = subtitleValues.prefix(Int(copiedSubtitles)).map { value -> SubtitleTrack in
            var mutableValue = value
            let title = swiftString(from: &mutableValue.title)
            let language = swiftString(from: &mutableValue.language)
            let codec = swiftString(from: &mutableValue.codec)
            return SubtitleTrack(
                id: value.id,
                title: title,
                language: language.isEmpty ? nil : language,
                codec: codec.isEmpty ? nil : codec,
                isExternal: value.external,
                isSelected: value.selected
            )
        }

        if selectFirstSubtitle, let firstSubtitleID = subtitles.first?.id {
            setSubtitle(id: firstSubtitleID)
            subtitles = subtitles.map { track in
                SubtitleTrack(
                    id: track.id,
                    title: track.title,
                    language: track.language,
                    codec: track.codec,
                    isExternal: track.isExternal,
                    isSelected: track.id == firstSubtitleID
                )
            }
        }

        let audioTracks = audioValues.prefix(Int(copiedAudio)).map { value -> AudioTrack in
            var mutableValue = value
            let title = swiftString(from: &mutableValue.title)
            let language = swiftString(from: &mutableValue.language)
            let codec = swiftString(from: &mutableValue.codec)
            return AudioTrack(
                id: value.id,
                title: title,
                language: language.isEmpty ? nil : language,
                codec: codec.isEmpty ? nil : codec,
                isExternal: value.external,
                isSelected: value.selected
            )
        }

        Task { @MainActor [weak self] in
            self?.state.subtitles = subtitles
            self?.state.audioTracks = audioTracks
        }
    }

    @MainActor
    func load(_ url: URL) {
        state.resetForLoad(url)
        command(["loadfile", url.path, "replace"])
        setPaused(false)
    }

    func stop() {
        command(["stop"])
    }

    func togglePause() {
        command(["cycle", "pause"])
    }

    func setPaused(_ paused: Bool) {
        setFlag(property: "pause", value: paused)
    }

    func seek(to seconds: Double) {
        command(["seek", String(seconds), "absolute+exact"])
    }

    func seek(by seconds: Double) {
        command(["seek", String(seconds), "relative+exact"])
    }

    func setVolume(_ volume: Double) {
        setDouble(property: "volume", value: min(max(volume, 0), 100))
    }

    func toggleMute() {
        command(["cycle", "mute"])
    }

    func setSubtitle(id: Int64?) {
        command(["set", "sid", id.map(String.init) ?? "no"])
    }

    func setAudio(id: Int64?) {
        command(["set", "aid", id.map(String.init) ?? "no"])
    }

    func loadSubtitle(_ url: URL) {
        command(["sub-add", url.path, "select"])
    }

    private func command(_ arguments: [String]) {
        onEventQueue { [weak self] handle in
            let storage = arguments.map { strdup($0) }
            defer {
                storage.forEach { pointer in
                    if let pointer { free(pointer) }
                }
            }
            var pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
                guard let pointer else { return nil }
                return UnsafePointer<CChar>(pointer)
            }
            pointers.append(nil)
            var error = [CChar](repeating: 0, count: 512)
            let result = pointers.withUnsafeBufferPointer { argumentsPointer in
                error.withUnsafeMutableBufferPointer { errorPointer in
                    mvp_mpv_command_async(
                        handle,
                        argumentsPointer.baseAddress,
                        errorPointer.baseAddress,
                        errorPointer.count
                    )
                }
            }
            if result < 0 {
                self?.publishImmediateError(error)
            }
        }
    }

    private func setFlag(property: String, value: Bool) {
        onEventQueue { [weak self] handle in
            var error = [CChar](repeating: 0, count: 512)
            let result = property.withCString { propertyPointer in
                error.withUnsafeMutableBufferPointer { errorPointer in
                    mvp_mpv_set_flag_async(
                        handle,
                        propertyPointer,
                        value,
                        errorPointer.baseAddress,
                        errorPointer.count
                    )
                }
            }
            if result < 0 {
                self?.publishImmediateError(error)
            }
        }
    }

    private func setDouble(property: String, value: Double) {
        onEventQueue { [weak self] handle in
            var error = [CChar](repeating: 0, count: 512)
            let result = property.withCString { propertyPointer in
                error.withUnsafeMutableBufferPointer { errorPointer in
                    mvp_mpv_set_double_async(
                        handle,
                        propertyPointer,
                        value,
                        errorPointer.baseAddress,
                        errorPointer.count
                    )
                }
            }
            if result < 0 {
                self?.publishImmediateError(error)
            }
        }
    }

    private func publishImmediateError(_ buffer: [CChar]) {
        let message = buffer.withUnsafeBufferPointer {
            String(cString: $0.baseAddress!)
        }
        Task { @MainActor [weak self] in
            self?.state.errorMessage = message
        }
    }

    var rawHandle: OpaquePointer {
        handle
    }
}
