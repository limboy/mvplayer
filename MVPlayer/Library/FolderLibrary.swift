import Foundation
import UniformTypeIdentifiers

struct LibraryRoot: Identifiable, Equatable, Sendable {
    let id: UUID
    var url: URL
    var displayName: String
    var isAvailable: Bool
}

struct BrowserEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case video
    }

    let url: URL
    let kind: Kind

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

private struct PersistedRoot: Codable {
    let id: UUID
    var bookmark: Data?
    var fallbackPath: String
    var displayName: String
}

@MainActor
final class FolderLibrary: ObservableObject {
    @Published private(set) var roots: [LibraryRoot] = []
    @Published private(set) var navigationPath: [URL] = []
    @Published private(set) var entries: [BrowserEntry] = []
    @Published private(set) var metadata: [URL: MediaMetadata] = [:]
    @Published var selectedVideo: URL?
    @Published var errorMessage: String?

    var onVisibleVideosChanged: ((URL?, [URL]) -> Void)?

    private let fileManager: FileManager
    private let storageURL: URL
    private var watcher: FolderWatcher?
    private var refreshTask: Task<Void, Never>?
    private var metadataTasks: [URL: Task<Void, Never>] = [:]

    /// What is taken for video when the system has no content type for the file,
    /// which is most of what only mpv can open. Also what the open panel and the
    /// app's document types are built from, so all three agree.
    nonisolated static let videoExtensions: Set<String> = [
        "3g2", "3gp", "asf", "avi", "divx", "dv", "f4v", "flv", "m2t", "m2ts",
        "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "ogm", "ogv", "rm",
        "rmvb", "ts", "vob", "webm", "wmv"
    ]

    init(
        fileManager: FileManager = .default,
        storageURL: URL? = nil,
        startWatching: Bool = true
    ) {
        self.fileManager = fileManager
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.storageURL = applicationSupport
                .appendingPathComponent("MVPlayer", isDirectory: true)
                .appendingPathComponent("library.json")
        }
        restore()
        if startWatching {
            rebuildWatcher()
        }
    }

    deinit {
        refreshTask?.cancel()
        metadataTasks.values.forEach { $0.cancel() }
    }

    var currentDirectory: URL? {
        navigationPath.last
    }

    var isAtRootList: Bool {
        navigationPath.isEmpty
    }

    var currentTitle: String {
        currentDirectory?.lastPathComponent ?? "Folders"
    }

    var visibleVideos: [URL] {
        entries.compactMap { $0.kind != .folder ? $0.url : nil }
    }

    @discardableResult
    func addFolders(_ urls: [URL]) -> Bool {
        var added = false
        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                continue
            }
            guard !roots.contains(where: { $0.url.standardizedFileURL == url }) else {
                continue
            }
            roots.append(
                LibraryRoot(
                    id: UUID(),
                    url: url,
                    displayName: url.lastPathComponent,
                    isAvailable: true
                )
            )
            added = true
        }

        if added {
            sortRoots()
            persist()
            rebuildWatcher()
        }
        return added
    }

    func removeRoot(id: UUID) {
        guard let removed = roots.first(where: { $0.id == id }) else { return }
        roots.removeAll(where: { $0.id == id })
        if navigationPath.contains(where: { $0.path.hasPrefix(removed.url.path) }) {
            navigationPath = []
            entries = []
            selectedVideo = nil
            onVisibleVideosChanged?(nil, [])
        }
        persist()
        rebuildWatcher()
    }

    func replaceRoot(id: UUID, with rawURL: URL) {
        let url = rawURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let index = roots.firstIndex(where: { $0.id == id })
        else {
            return
        }

        roots[index].url = url
        roots[index].displayName = url.lastPathComponent
        roots[index].isAvailable = true
        sortRoots()
        persist()
        rebuildWatcher()
    }

    func openRoot(_ root: LibraryRoot) {
        guard root.isAvailable else { return }
        navigationPath = [root.url]
        refreshVisibleDirectory()
    }

    func openFolder(_ url: URL) {
        guard isDirectory(url) else { return }
        navigationPath.append(url.standardizedFileURL)
        refreshVisibleDirectory()
    }

    func goBack() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
        refreshVisibleDirectory()
    }

    func goToRootList() {
        navigationPath = []
        entries = []
        selectedVideo = nil
        onVisibleVideosChanged?(nil, [])
    }

    func selectVideo(_ url: URL) {
        selectedVideo = url
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refreshAll()
        }
    }

    func refreshAll() {
        for index in roots.indices {
            roots[index].isAvailable = isDirectory(roots[index].url)
        }

        while let directory = navigationPath.last, !isDirectory(directory) {
            navigationPath.removeLast()
        }
        refreshVisibleDirectory()
    }

    func refreshVisibleDirectory() {
        guard let directory = currentDirectory else {
            entries = []
            onVisibleVideosChanged?(nil, [])
            return
        }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isHiddenKey,
                    .contentTypeKey
                ],
                options: [.skipsHiddenFiles]
            )

            entries = urls.compactMap(Self.makeEntry)
                .sorted(by: Self.entrySort)

            loadMetadata(for: entries.compactMap { entry in
                entry.kind != .folder ? entry.url : nil
            })

            if let selectedVideo, !entries.contains(where: { $0.url == selectedVideo }) {
                self.selectedVideo = nil
            }
            onVisibleVideosChanged?(directory, visibleVideos)
        } catch {
            entries = []
            errorMessage = "Could not read \(directory.lastPathComponent): \(error.localizedDescription)"
            onVisibleVideosChanged?(directory, [])
        }
    }

    func metadata(for url: URL) -> MediaMetadata? {
        metadata[url.standardizedFileURL]
    }

    private func loadMetadata(for urls: [URL]) {
        let normalizedURLs = Set(urls.map(\.standardizedFileURL))
        for url in normalizedURLs where metadata[url] == nil && metadataTasks[url] == nil {
            metadataTasks[url] = Task { [weak self] in
                let value = await Task.detached(priority: .utility) {
                    await MediaMetadata.load(for: url)
                }.value
                guard !Task.isCancelled else { return }
                self?.metadataTasks[url] = nil
                if let value {
                    self?.metadata[url] = value
                }
            }
        }
    }

    nonisolated static func isVideo(_ url: URL) -> Bool {
        let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
        guard resourceValues?.isRegularFile != false else { return false }
        if let contentType = resourceValues?.contentType,
           contentType.conforms(to: .movie)
        {
            return true
        }
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    private static func makeEntry(_ url: URL) -> BrowserEntry? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
        if values?.isHidden == true {
            return nil
        }
        if values?.isDirectory == true {
            return BrowserEntry(url: url.standardizedFileURL, kind: .folder)
        }
        if isVideo(url) {
            return BrowserEntry(url: url.standardizedFileURL, kind: .video)
        }
        return nil
    }

    private static func entrySort(_ lhs: BrowserEntry, _ rhs: BrowserEntry) -> Bool {
        if (lhs.kind == .folder) != (rhs.kind == .folder) {
            return lhs.kind == .folder
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func sortRoots() {
        roots.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func rebuildWatcher() {
        let paths = roots.filter(\.isAvailable).map(\.url.path)
        watcher = FolderWatcher(paths: paths) { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storageURL),
              let storedRoots = try? JSONDecoder().decode([PersistedRoot].self, from: data)
        else {
            return
        }

        roots = storedRoots.map { stored in
            // Nothing reads this back. A stale bookmark still resolves to the
            // right place, and the persist below rewrites every bookmark from
            // the URL it resolved to, so staleness is answered by that rather
            // than by branching here. The parameter is not optional, hence the
            // variable.
            var isStale = false
            let resolvedURL = stored.bookmark.flatMap {
                try? URL(
                    resolvingBookmarkData: $0,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } ?? URL(fileURLWithPath: stored.fallbackPath, isDirectory: true)
            return LibraryRoot(
                id: stored.id,
                url: resolvedURL.standardizedFileURL,
                displayName: stored.displayName,
                isAvailable: isDirectory(resolvedURL)
            )
        }
        sortRoots()

        // Writes the roots straight back, which is what refreshes bookmarks
        // that have gone stale. The count check this used to carry could not
        // fail, because `map` returns one root per stored root.
        persist()
    }

    private func persist() {
        let storedRoots = roots.map { root in
            PersistedRoot(
                id: root.id,
                bookmark: try? root.url.bookmarkData(
                    options: [.minimalBookmark],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ),
                fallbackPath: root.url.path,
                displayName: root.displayName
            )
        }

        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(storedRoots)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            errorMessage = "Could not save the folder library: \(error.localizedDescription)"
        }
    }
}
