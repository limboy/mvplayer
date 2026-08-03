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
    guard let context else { return }
    Unmanaged<MPVPlayerEngine>
        .fromOpaque(context)
        .takeUnretainedValue()
        .scheduleEventDrain()
}

final class MPVPlayerEngine: @unchecked Sendable {
    let info: LibMPVInfo
    let state: PlayerState

    var onPlaybackEnded: (@MainActor () -> Void)?
    var onFileLoaded: (@MainActor () -> Void)?

    private let handle: OpaquePointer
    private let eventQueue = DispatchQueue(label: "com.example.MVPlayer.mpv-events")
    private var isShuttingDown = false

    init(state: PlayerState) throws {
        switch LibMPVLoader.createPlayer() {
        case .success(let result):
            handle = result.0
            info = result.1
            self.state = state
        case .failure(let error):
            throw error
        }

        mvp_mpv_set_wakeup_callback(
            handle,
            mpvWakeupCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        scheduleEventDrain()
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        mvp_mpv_set_wakeup_callback(handle, nil, nil)
        mvp_mpv_destroy(handle)
    }

    func scheduleEventDrain() {
        guard !isShuttingDown else { return }
        eventQueue.async { [weak self] in
            self?.drainEvents()
        }
    }

    private func drainEvents() {
        guard !isShuttingDown else { return }
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
            publishImmediateError(error)
        }
    }

    private func setFlag(property: String, value: Bool) {
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
            publishImmediateError(error)
        }
    }

    private func setDouble(property: String, value: Double) {
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
            publishImmediateError(error)
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
