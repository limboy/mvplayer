import AppKit
import SwiftUI

struct FolderBrowserView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject private var library: FolderLibrary
    @ObservedObject private var state: PlayerState
    @State private var isDropTargeted = false

    init(appModel: AppModel) {
        self.appModel = appModel
        _library = ObservedObject(wrappedValue: appModel.folderLibrary)
        _state = ObservedObject(wrappedValue: appModel.playerState)
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
                    Text(progressText(for: entry.url))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            state.currentURL == entry.url
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
    }

    private func progressText(for url: URL) -> String {
        "\(Int((displayedProgress(for: url) * 100).rounded(.down)))%"
    }

    private func displayedProgress(for url: URL) -> Double {
        if state.currentURL?.standardizedFileURL == url.standardizedFileURL,
           state.duration.isFinite,
           state.duration > 0
        {
            let fraction = min(max(state.currentTime / state.duration, 0), 1)
            return fraction
        }

        let progress = appModel.playbackProgress(for: url)
        return progress?.fraction ?? 0
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
