import AppKit
import SwiftUI

struct FolderBrowserView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject private var library: FolderLibrary
    @State private var isDropTargeted = false

    /// The row the arrow keys are moving over, which is not the row being
    /// played: browsing ahead of what is on screen is the point of it.
    @State private var selection: URL?
    @FocusState private var isListFocused: Bool

    /// Held, deliberately, without observing it. The only things here that move
    /// with playback are one row's percentage and one row's highlight, and both
    /// live in leaves of their own. Observing the player from the browser
    /// itself would rebuild every row in the folder each time the clock ticks.
    private let state: PlayerState

    init(appModel: AppModel) {
        self.appModel = appModel
        _library = ObservedObject(wrappedValue: appModel.folderLibrary)
        state = appModel.playerState
    }

    var body: some View {
        VStack(spacing: 0) {
            browserHeader
            Divider()
            browserContent
            Divider()
            statusBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.addFolders(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onChange(of: library.entries) { _, _ in normalizeSelection() }
        .onChange(of: library.roots) { _, _ in normalizeSelection() }
        .onAppear(perform: normalizeSelection)
    }

    /// Keeps the arrow keys pointed at a row that is still there, and gives
    /// them somewhere to start from in a folder that has just been opened.
    private func normalizeSelection() {
        let available = library.isAtRootList
            ? library.roots.map(\.url)
            : library.entries.map(\.url)
        if selection == nil || !available.contains(selection!) {
            selection = available.first
        }
    }

    private func openSelection() {
        guard let selection else { return }
        if library.isAtRootList {
            guard let root = library.roots.first(where: { $0.url == selection }) else { return }
            open(root)
        } else {
            guard let entry = library.entries.first(where: { $0.url == selection }) else { return }
            open(entry)
        }
    }

    private func open(_ root: LibraryRoot) {
        guard root.isAvailable else { return }
        library.openRoot(root)
    }

    private func open(_ entry: BrowserEntry) {
        switch entry.kind {
        case .folder:
            library.openFolder(entry.url)
        case .video:
            appModel.play(
                entry.url,
                from: library.visibleVideos,
                directory: library.currentDirectory
            )
        }
    }

    /// Clicking a row moves the keyboard's place in the list to it and hands
    /// the list focus, so the arrow keys carry on from wherever the mouse
    /// left off rather than from the top.
    private func selectFromClick(_ url: URL) {
        selection = url
        isListFocused = true
    }

    private var browserHeader: some View {
        ViewThatFits(in: .horizontal) {
            browserHeaderContent(showsItemCount: true)
            browserHeaderContent(showsItemCount: false)
        }
        .padding(.horizontal, library.isAtRootList ? 16 : 10)
        .frame(height: 42)
    }

    private func browserHeaderContent(showsItemCount: Bool) -> some View {
        HStack(spacing: 6) {
            if !library.isAtRootList {
                Button {
                    library.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Back")
            }

            Text(library.currentTitle)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            if showsItemCount, !library.isAtRootList {
                Text("\(library.entries.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

        }
    }

    /// What is known about the selected row, along the bottom of the browser.
    ///
    /// The library has been reading this for every video it lists since before
    /// there was anywhere to show it; the row itself has no space for more than
    /// a name and how far in the viewer is.
    private var statusBar: some View {
        HStack(spacing: 10) {
            // The floor is what the details are measured against: they may take
            // the rest of the bar, but never the name's last 120 points. A name
            // longer than what is left loses its middle, where the least of it
            // is — the extension and the leading words survive.
            Text(statusTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, alignment: .leading)

            Spacer(minLength: 0)

            // Widest first: a bar too narrow for all of it gives up the file
            // size, then the frame rate, and keeps the running time longest.
            ViewThatFits(in: .horizontal) {
                statusDetailText(statusDetails)
                statusDetailText(Array(statusDetails.dropLast()))
                statusDetailText(Array(statusDetails.prefix(1)))
                Color.clear.frame(width: 0)
            }
            .layoutPriority(1)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private func statusDetailText(_ details: [String]) -> some View {
        Text(details.joined(separator: "  ·  "))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private var statusTitle: String {
        if let selectedRoot {
            return selectedRoot.displayName
        }
        if let selectedEntry {
            return selectedEntry.name
        }
        return ""
    }

    private var statusDetails: [String] {
        if let selectedRoot {
            return selectedRoot.isAvailable ? [selectedRoot.url.path] : ["Unavailable"]
        }
        guard let selectedEntry else { return [] }
        switch selectedEntry.kind {
        case .folder:
            return ["Folder"]
        case .video:
            // Empty until the read of the file comes back, rather than a row of
            // placeholders that would only be replaced a moment later.
            return library.metadata(for: selectedEntry.url)?.summaryParts ?? []
        }
    }

    private var selectedRoot: LibraryRoot? {
        guard library.isAtRootList, let selection else { return nil }
        return library.roots.first { $0.url == selection }
    }

    private var selectedEntry: BrowserEntry? {
        guard !library.isAtRootList, let selection else { return nil }
        return library.entries.first { $0.url == selection }
    }

    @ViewBuilder
    private var browserContent: some View {
        if library.isAtRootList {
            if library.roots.isEmpty {
                ContentUnavailableView {
                    Label("Add a Video Folder", systemImage: "folder.badge.plus")
                } description: {
                    Text("Drag a folder here, or use Choose Folder.")
                } actions: {
                    Button("Choose Folder…") {
                        chooseFolders()
                    }
                }
            } else {
                List(selection: $selection) {
                    ForEach(library.roots) { root in
                        rootRow(root)
                            .tag(root.url)
                    }
                }
                .listStyle(.inset)
                .modifier(KeyboardNavigation(isFocused: $isListFocused, open: openSelection))
            }
        } else if library.entries.isEmpty {
            ContentUnavailableView(
                "No Videos Here",
                systemImage: "film",
                description: Text("This folder has no supported video files or subfolders.")
            )
        } else {
            List(selection: $selection) {
                ForEach(library.entries) { entry in
                    entryRow(entry)
                        .tag(entry.url)
                }
            }
            .listStyle(.inset)
            .modifier(KeyboardNavigation(isFocused: $isListFocused, open: openSelection))
        }
    }

    @ViewBuilder
    private func rootRow(_ root: LibraryRoot) -> some View {
        if root.isAvailable {
            Button {
                selectFromClick(root.url)
                open(root)
            } label: {
                rootLabel(root)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Remove Folder", role: .destructive) {
                    library.removeRoot(id: root.id)
                }
            }
        } else {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(root.displayName)
                        .lineLimit(1)
                    Text(root.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Reconnect") {
                    reconnect(root)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .contextMenu {
                Button("Reconnect…") {
                    reconnect(root)
                }
                Button("Remove Folder", role: .destructive) {
                    library.removeRoot(id: root.id)
                }
            }
        }
    }

    private func rootLabel(_ root: LibraryRoot) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(root.displayName)
                    .lineLimit(1)
                Text(root.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func entryRow(_ entry: BrowserEntry) -> some View {
        Button {
            selectFromClick(entry.url)
            open(entry)
        } label: {
            HStack(spacing: 10) {
                if entry.kind == .folder {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                }
                Text(entry.name)
                    .lineLimit(1)
                Spacer()
                if entry.kind == .folder {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                } else {
                    PlaybackProgressIndicator(
                        state: state,
                        url: entry.url,
                        stored: appModel.playbackProgress(for: entry.url)
                    )
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(NowPlayingRowBackground(state: state, url: entry.url))
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add Video Folder"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.presentAsSheet { urls in
            library.addFolders(urls)
        }
    }

    private func reconnect(_ root: LibraryRoot) {
        let panel = NSOpenPanel()
        panel.title = "Reconnect \(root.displayName)"
        panel.prompt = "Reconnect"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.presentAsSheet { urls in
            guard let url = urls.first else { return }
            library.replaceRoot(id: root.id, with: url)
        }
    }
}

/// How far into one video the viewer is, for rows where that is worth saying at
/// all: a bar for something part-watched, a tick for something finished, and
/// nothing whatsoever for a file that has never been opened. A column of "0%"
/// against every unwatched file was noise standing exactly where the eye looks
/// to find the few rows that do carry a state.
///
/// Only the row being played moves, but every row asks the player whether it is
/// that row, so this stays a leaf: a position update redraws a handful of small
/// views instead of the whole browser.
private struct PlaybackProgressIndicator: View {
    @ObservedObject var state: PlayerState
    let url: URL

    /// What the row shows when it is not the one playing. Read from the
    /// progress store by the browser, which redraws when the store changes.
    let stored: PlaybackProgress?

    private static let barWidth: CGFloat = 40

    var body: some View {
        content
            .frame(width: 46, alignment: .trailing)
    }

    @ViewBuilder
    private var content: some View {
        if isWatched {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Watched")
        } else if fraction > 0 {
            Capsule()
                .fill(.quaternary)
                .frame(width: Self.barWidth, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: Self.barWidth * fraction, height: 4)
                }
                .help("\(Int((fraction * 100).rounded(.down)))% watched")
        }
    }

    private var isPlayingThisRow: Bool {
        state.currentURL?.standardizedFileURL == url.standardizedFileURL
            && state.duration.isFinite
            && state.duration > 0
    }

    /// Finished, and not being watched again right now — a rewatch shows its
    /// own position rather than the tick left by the previous time through.
    private var isWatched: Bool {
        !isPlayingThisRow && stored?.isCompleted == true
    }

    private var fraction: Double {
        guard isPlayingThisRow else { return stored?.fraction ?? 0 }
        return min(max(state.currentTime / state.duration, 0), 1)
    }
}

/// Focus and Return, shared by the folder browser's two lists.
///
/// The lists move their own selection with the arrow keys once they hold focus,
/// which is why `PlayerKeyboardMonitor` hands the vertical arrows to whatever
/// list is focused instead of turning them into volume.
private struct KeyboardNavigation: ViewModifier {
    @FocusState.Binding var isFocused: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onKeyPress(.return) {
                open()
                return .handled
            }
    }
}

/// Marks the row being played. A leaf for the same reason as the label.
private struct NowPlayingRowBackground: View {
    @ObservedObject var state: PlayerState
    let url: URL

    var body: some View {
        state.currentURL == url ? Color.accentColor.opacity(0.18) : Color.clear
    }
}
