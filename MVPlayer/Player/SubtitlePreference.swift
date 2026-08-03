import Foundation

/// Whether a new file should open with a subtitle track showing.
///
/// Which track that is stays mpv's decision — this only says whether it gets to
/// make one. Somebody who never wants subtitles can turn it off once instead of
/// choosing "Off" for every file.
enum SubtitlePreference {
    static let defaultsKey = "SubtitlesEnabledByDefault"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}
