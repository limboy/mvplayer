import AppKit
import SwiftUI

struct FolderBrowserView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject private var library: FolderLibrary
    @State private var isDropTargeted = false

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
                List {
                    ForEach(library.roots) { root in
                        rootRow(root)
                    }
                }
                .listStyle(.inset)
            }
        } else if library.entries.isEmpty {
            ContentUnavailableView(
                "No Videos Here",
                systemImage: "film",
                description: Text("This folder has no supported video files or subfolders.")
            )
        } else {
            List {
                ForEach(library.entries) { entry in
                    entryRow(entry)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func rootRow(_ root: LibraryRoot) -> some View {
        if root.isAvailable {
            Button {
                library.openRoot(root)
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
                    PlaybackProgressLabel(
                        state: state,
                        url: entry.url,
                        storedFraction: appModel.playbackProgress(for: entry.url)?.fraction ?? 0
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
        if panel.runModal() == .OK {
            _ = library.addFolders(panel.urls)
        }
    }

    private func reconnect(_ root: LibraryRoot) {
        let panel = NSOpenPanel()
        panel.title = "Reconnect \(root.displayName)"
        panel.prompt = "Reconnect"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            library.replaceRoot(id: root.id, with: url)
        }
    }
}

/// The percentage for one row. Only the row being played moves, but every row
/// asks the player whether it is that row, so this stays a leaf: a position
/// update redraws a handful of small labels instead of the whole browser.
private struct PlaybackProgressLabel: View {
    @ObservedObject var state: PlayerState
    let url: URL

    /// What the row shows when it is not the one playing. Read from the
    /// progress store by the browser, which redraws when the store changes.
    let storedFraction: Double

    var body: some View {
        Text("\(Int((fraction * 100).rounded(.down)))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, alignment: .trailing)
    }

    private var fraction: Double {
        guard state.currentURL?.standardizedFileURL == url.standardizedFileURL,
              state.duration.isFinite,
              state.duration > 0
        else {
            return storedFraction
        }
        return min(max(state.currentTime / state.duration, 0), 1)
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
