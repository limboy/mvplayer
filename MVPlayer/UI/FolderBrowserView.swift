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
        HStack(spacing: 10) {
            Button {
                library.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(library.isAtRootList)
            .help("Back")

            Image(systemName: library.isAtRootList ? "square.stack.3d.up" : "folder.fill")
                .foregroundStyle(library.isAtRootList ? Color.secondary : Color.accentColor)

            Text(library.currentTitle)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            if !library.isAtRootList {
                Text("\(library.entries.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                library.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Button {
                chooseFolders()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Add Folder")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    @ViewBuilder
    private var browserContent: some View {
        if library.isAtRootList {
            if library.roots.isEmpty {
                ContentUnavailableView {
                    Label("Add a Video Folder", systemImage: "folder.badge.plus")
                } description: {
                    Text("Drag a folder here, or click +.")
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
                Image(systemName: "folder.badge.questionmark")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(root.displayName)
                        .lineLimit(1)
                    Text(root.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(root.displayName)
                    .lineLimit(1)
                Text(root.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                Image(systemName: entry.kind == .folder ? "folder.fill" : "film")
                    .foregroundStyle(entry.kind == .folder ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                Text(entry.name)
                    .lineLimit(1)
                Spacer()
                if entry.kind == .folder {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                } else if state.currentURL == entry.url {
                    Image(systemName: state.isPaused ? "pause.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            state.currentURL == entry.url
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
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
