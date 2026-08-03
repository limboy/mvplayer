import Foundation

struct SubtitleTrack: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let language: String?
    let codec: String?
    let isExternal: Bool
    let isSelected: Bool

    var displayName: String {
        if !title.isEmpty {
            return title
        }
        if let language, !language.isEmpty {
            return language.uppercased()
        }
        if let codec, !codec.isEmpty {
            return "\(codec.uppercased()) subtitle"
        }
        return "Subtitle \(id)"
    }
}

struct AudioTrack: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let language: String?
    let codec: String?
    let isExternal: Bool
    let isSelected: Bool

    var displayName: String {
        if !title.isEmpty {
            return title
        }
        if let language, !language.isEmpty {
            return language.uppercased()
        }
        if let codec, !codec.isEmpty {
            return codec.uppercased()
        }
        return "Audio (id)"
    }
}

@MainActor
final class PlayerState: ObservableObject {
    @Published var isPaused = true
    @Published var isMuted = false
    @Published var isLoading = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 100
    @Published var currentURL: URL?
    @Published var subtitles: [SubtitleTrack] = []
    @Published var audioTracks: [AudioTrack] = []
    @Published var errorMessage: String?

    var hasMedia: Bool {
        currentURL != nil
    }

    var selectedSubtitleID: Int64? {
        subtitles.first(where: \.isSelected)?.id
    }

    func resetForLoad(_ url: URL) {
        currentURL = url
        currentTime = 0
        duration = 0
        isLoading = true
        errorMessage = nil
        subtitles = []
        audioTracks = []
    }
}
