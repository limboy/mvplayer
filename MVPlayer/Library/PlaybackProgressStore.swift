import Foundation

struct PlaybackProgress: Codable, Equatable, Identifiable, Sendable {
    let url: URL
    var position: Double
    var duration: Double
    var lastPlayed: Date
    var isCompleted: Bool

    var id: URL { url }

    var fraction: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

@MainActor
final class PlaybackProgressStore: ObservableObject {
    @Published private(set) var entries: [PlaybackProgress] = []

    /// The same entries keyed for lookup. The browser asks for progress once
    /// per visible row every time the list redraws, and scanning the array
    /// meant normalizing every stored URL on each of those calls.
    private var entriesByURL: [URL: PlaybackProgress] = [:]

    private let storageURL: URL

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.storageURL = applicationSupport
                .appendingPathComponent("MVPlayer", isDirectory: true)
                .appendingPathComponent("progress.json")
        }
        restore()
    }

    func progress(for url: URL) -> PlaybackProgress? {
        entriesByURL[url.standardizedFileURL]
    }

    func record(url: URL, position: Double, duration: Double) {
        guard position.isFinite, position >= 0 else { return }
        let normalizedURL = url.standardizedFileURL
        let normalizedDuration = duration.isFinite && duration > 0 ? duration : 0
        let completed = normalizedDuration > 0
            && (position >= normalizedDuration * 0.95 || normalizedDuration - position <= 30)
        let value = PlaybackProgress(
            url: normalizedURL,
            position: min(position, normalizedDuration > 0 ? normalizedDuration : position),
            duration: normalizedDuration,
            lastPlayed: Date(),
            isCompleted: completed
        )

        if let index = entries.firstIndex(where: { $0.url.standardizedFileURL == normalizedURL }) {
            entries[index] = value
        } else {
            entries.append(value)
        }
        entries.sort { $0.lastPlayed > $1.lastPlayed }
        entriesByURL[normalizedURL] = value
        persist()
    }

    func markFinished(url: URL, duration: Double) {
        record(url: url, position: duration, duration: duration)
    }

    func remove(url: URL) {
        entries.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        entriesByURL[url.standardizedFileURL] = nil
        persist()
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storageURL),
              let values = try? JSONDecoder().decode([PlaybackProgress].self, from: data)
        else {
            return
        }
        entries = values.sorted { $0.lastPlayed > $1.lastPlayed }
        entriesByURL = Dictionary(
            entries.map { ($0.url.standardizedFileURL, $0) },
            // A file recorded twice under different spellings of the same path
            // keeps the more recent entry, which sorted first.
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Playback progress is best-effort and should never interrupt playback.
        }
    }
}
