import CoreServices
import Foundation

/// Calls `onChange` when anything under the watched folders changes, coalesced by FSEvents latency.
public final class FolderWatcher {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "inkrelay.folder-watcher")
    private var stream: FSEventStreamRef?

    public init(urls: [URL], latency: TimeInterval = 3, onChange: @escaping () -> Void) {
        self.paths = urls.map(\.path)
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    /// Returns false if FSEvents refused the stream, in which case the caller falls back to rescans.
    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return false
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
