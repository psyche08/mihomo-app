import CoreServices
import Foundation

/// Wakes App Proxy maintenance when an application or CLI update changes a discovery root,
/// instead of leaving the new code to the next 20-second pass. FSEvents coalesces a burst
/// (an updater replacing a bundle) into one callback; the pass decides whether anything changed.
/// Owned by the coordinator for the process lifetime.
final class AppProxyUpdateWatcher {
    private var stream: FSEventStreamRef?
    private(set) var paths: [String] = []
    private let queue = DispatchQueue(label: "dev.linsheng.mihomo-app.app-proxy-updates")
    private let onChange: @Sendable () -> Void
    static let latency: CFTimeInterval = 3

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    deinit { stop() }

    /// Watch the existing directories among `candidates`; unchanged sets keep the current stream.
    func watch(_ candidates: [String]) {
        let existing = Array(Set(candidates.filter { candidate in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) && isDirectory.boolValue
        })).sorted()
        guard existing != paths || (stream == nil && !existing.isEmpty) else { return }
        stop()
        paths = existing
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AppProxyUpdateWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
                                                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        paths = []
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
