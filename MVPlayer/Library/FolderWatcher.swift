import CoreServices
import Foundation

final class FolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.example.MVPlayer.folder-events")
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, callbackInfo, _, _, _, _ in
                guard let callbackInfo else { return }
                let watcher = Unmanaged<FolderWatcher>
                    .fromOpaque(callbackInfo)
                    .takeUnretainedValue()
                watcher.onChange()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagUseCFTypes
            )
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
