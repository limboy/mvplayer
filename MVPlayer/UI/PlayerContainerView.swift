import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerContainerView: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    let videoView: MVVideoView
    @ObservedObject var windowState: WindowState
    let isVideoSurfaceActive: Bool

    @ObservedObject private var state: PlayerState
    @ObservedObject private var queue: PlaybackQueue
    @State private var controlsVisible = true
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var hideTask: Task<Void, Never>?

    init(
        appModel: AppModel,
        engine: MPVPlayerEngine,
        videoView: MVVideoView,
        windowState: WindowState,
        isVideoSurfaceActive: Bool = true
    ) {
        self.appModel = appModel
        self.engine = engine
        self.videoView = videoView
        self.windowState = windowState
        self.isVideoSurfaceActive = isVideoSurfaceActive
        _state = ObservedObject(wrappedValue: appModel.playerState)
        _queue = ObservedObject(wrappedValue: appModel.playbackQueue)
    }

    var body: some View {
        ZStack {
            Color.black

            VideoSurface(view: videoView, isActive: isVideoSurfaceActive)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    windowState.toggleFullscreen()
                }

            if !state.hasMedia {
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 46, weight: .light))
                    Text("Choose a video below")
                        .font(.headline)
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }

            if state.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack {
                if let error = state.errorMessage {
                    errorBanner(error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                if state.hasMedia {
                    PlayerControlsView(
                        appModel: appModel,
                        engine: engine,
                        windowState: windowState,
                        state: state,
                        queue: queue,
                        isSeeking: $isSeeking,
                        seekValue: $seekValue
                    )
                    .opacity(controlsVisible ? 1 : 0)
                    .offset(y: controlsVisible ? 0 : 14)
                    .allowsHitTesting(controlsVisible)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: controlsVisible)
            .animation(.easeOut(duration: 0.18), value: state.hasMedia)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                revealControls()
            case .ended:
                scheduleControlsHide()
            }
        }
        .onChange(of: state.isPaused) { _, isPaused in
            if isPaused {
                hideTask?.cancel()
                controlsVisible = true
            } else {
                scheduleControlsHide()
            }
        }
        .onDisappear {
            hideTask?.cancel()
        }
        .background {
            PlaybackKeyboardMonitor {
                appModel.togglePlayPause()
            }
            .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
            Button {
                state.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding()
    }

    private func revealControls() {
        controlsVisible = true
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideTask?.cancel()
        guard !state.isPaused, !isSeeking else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !state.isPaused, !isSeeking else { return }
            controlsVisible = false
        }
    }
}

private struct PlaybackKeyboardMonitor: NSViewRepresentable {
    let togglePlayPause: @MainActor () -> Void

    func makeNSView(context: Context) -> PlaybackKeyboardMonitorView {
        let view = PlaybackKeyboardMonitorView()
        view.togglePlayPause = togglePlayPause
        return view
    }

    func updateNSView(_ nsView: PlaybackKeyboardMonitorView, context: Context) {
        nsView.togglePlayPause = togglePlayPause
    }

    static func dismantleNSView(
        _ nsView: PlaybackKeyboardMonitorView,
        coordinator: Void
    ) {
        nsView.stopMonitoring()
    }
}

@MainActor
private final class PlaybackKeyboardMonitorView: NSView {
    var togglePlayPause: (@MainActor () -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, event.window === window else { return event }
            guard event.charactersIgnoringModifiers == " " else { return event }

            let actionModifiers: NSEvent.ModifierFlags = [
                .command, .control, .option, .shift
            ]
            guard event.modifierFlags.intersection(actionModifiers).isEmpty else {
                return event
            }

            if !event.isARepeat {
                togglePlayPause?()
            }
            return nil
        }
    }

    func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }
}

private struct PlayerControlsView: View {
    @ObservedObject var appModel: AppModel
    let engine: MPVPlayerEngine
    @ObservedObject var windowState: WindowState
    @ObservedObject var state: PlayerState
    @ObservedObject var queue: PlaybackQueue
    @Binding var isSeeking: Bool
    @Binding var seekValue: Double
    @State private var isVolumePopoverPresented = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularControls
            compactControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var regularControls: some View {
        HStack(spacing: 12) {
            transportControls

            Divider()
                .frame(height: 18)

            volumeControl

            currentTimeLabel
            seekSlider
                .frame(minWidth: 120)
                .layoutPriority(1)
            durationLabel

            secondaryControls
        }
        // Including the surrounding padding, this layout is selected at
        // approximately 630 points or wider.
        .frame(minWidth: 560)
    }

    private var compactControls: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                HStack {
                    Text(timeString(isSeeking ? seekValue : state.currentTime))
                    Spacer()
                    Text(timeString(state.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                seekSlider
                    .frame(minWidth: 80)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 14) {
                transportControls

                volumeControl

                Spacer(minLength: 4)
                secondaryControls
            }
        }
    }

    @ViewBuilder
    private var transportControls: some View {
        Group {
            controlButton("backward.end.fill", help: "Previous video") {
                appModel.playPrevious()
            }

            controlButton(
                state.isPaused ? "play.fill" : "pause.fill",
                size: 20,
                help: state.isPaused ? "Play" : "Pause"
            ) {
                appModel.togglePlayPause()
            }

            controlButton("forward.end.fill", help: "Next video") {
                appModel.playNext()
            }
        }
    }

    private var currentTimeLabel: some View {
        Text(timeString(isSeeking ? seekValue : state.currentTime))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: 54, alignment: .trailing)
    }

    private var seekSlider: some View {
        TimelinePreviewScrubber(
            currentTime: state.currentTime,
            duration: state.duration,
            url: state.currentURL,
            isSeeking: $isSeeking,
            seekValue: $seekValue
        ) { value in
            engine.seek(to: value)
        }
    }

    private var durationLabel: some View {
        Text(timeString(state.duration))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: 54, alignment: .leading)
    }

    @ViewBuilder
    private var secondaryControls: some View {
        Group {
            audioMenu
            subtitleMenu

            controlButton(
                "shuffle",
                foregroundStyle: queue.isShuffled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary),
                help: queue.isShuffled ? "Shuffle On" : "Shuffle Off"
            ) {
                queue.isShuffled.toggle()
            }

            controlButton(
                queue.repeatMode.symbolName,
                foregroundStyle: queue.repeatMode == .off
                    ? AnyShapeStyle(Color.primary)
                    : AnyShapeStyle(Color.accentColor),
                help: queue.repeatMode.label
            ) {
                queue.cycleRepeatMode()
            }

            controlButton(
                windowState.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: windowState.isFullscreen ? "Exit Full Screen" : "Enter Full Screen"
            ) {
                windowState.toggleFullscreen()
            }
        }
    }

    private var volumeSymbol: String {
        if state.isMuted || state.volume <= 0 {
            return "speaker.slash"
        }
        if state.volume <= 33 {
            return "speaker.wave.1"
        }
        if state.volume <= 66 {
            return "speaker.wave.2"
        }
        return "speaker.wave.3"
    }

    private var volumeControl: some View {
        Button {
            isVolumePopoverPresented.toggle()
        } label: {
            Image(systemName: volumeSymbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isVolumePopoverPresented, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        engine.toggleMute()
                    } label: {
                        Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help(state.isMuted ? "Unmute" : "Mute")

                    Text("Volume")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(state.volume.rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: Binding(
                    get: { state.volume },
                    set: {
                        state.volume = $0
                        engine.setVolume($0)
                    }
                ), in: 0...100)
                .frame(width: 190)
            }
            .padding(14)
            .frame(width: 220)
        }
        .help("Volume")
    }

    private var subtitleMenu: some View {
        Menu {
            Button {
                engine.setSubtitle(id: nil)
            } label: {
                subtitleLabel("Off", selected: state.selectedSubtitleID == nil)
            }

            if !state.subtitles.isEmpty {
                Divider()
                ForEach(state.subtitles) { track in
                    Button {
                        engine.setSubtitle(id: track.id)
                    } label: {
                        subtitleLabel(
                            track.displayName + (track.isExternal ? " — External" : ""),
                            selected: track.isSelected
                        )
                    }
                }
            }

            Divider()
            Button("Load Subtitle…") {
                chooseSubtitle()
            }
        } label: {
            Image(systemName: "captions.bubble")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Subtitles")
    }

    private var audioMenu: some View {
        Menu {
            if state.audioTracks.isEmpty {
                Text("No alternate audio tracks")
            } else {
                ForEach(state.audioTracks) { track in
                    Button {
                        engine.setAudio(id: track.id)
                    } label: {
                        subtitleLabel(
                            track.displayName + (track.isExternal ? " — External" : ""),
                            selected: track.isSelected
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "waveform")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Audio Tracks")
    }

    private func subtitleLabel(_ title: String, selected: Bool) -> some View {
        Label(title, systemImage: selected ? "checkmark" : "circle")
    }

    private func chooseSubtitle() {
        let panel = NSOpenPanel()
        panel.title = "Choose Subtitle"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub", "idx"]
            .compactMap { UTType(filenameExtension: $0) }

        if panel.runModal() == .OK, let url = panel.url {
            engine.loadSubtitle(url)
        }
    }

    private func controlButton(
        _ symbol: String,
        size: CGFloat = 15,
        foregroundStyle: AnyShapeStyle = AnyShapeStyle(Color.primary),
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(foregroundStyle)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
