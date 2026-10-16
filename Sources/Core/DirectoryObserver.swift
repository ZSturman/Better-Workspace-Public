import Foundation
#if os(macOS)
import CoreServices
#endif

#if os(macOS)

/// Watches directory trees and reports coalesced change notifications.
///
/// Uses FSEvents rather than per-directory `DispatchSource` vnode watches: the app
/// needs to notice a file appearing in any Workspace root folder plus the ingest inbox, and a
/// single stream over a couple of roots is far cheaper than hundreds of file descriptors.
public final class DirectoryObserver {

    /// Paths that changed, coalesced over `latency`.
    public typealias Handler = @Sendable ([String]) -> Void

    private var stream: FSEventStreamRef?
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.zacharysturman.BetterWorkspace.fsevents")
    private let latency: CFTimeInterval

    public init(latency: CFTimeInterval = 0.4, handler: @escaping Handler) {
        self.latency = latency
        self.handler = handler
    }

    deinit { stopInternal() }

    public func start(watching roots: [URL]) {
        stopInternal()
        guard roots.isEmpty == false else { return }
        let paths = roots.map { $0.standardizedFileURL.path } as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let observer = Unmanaged<DirectoryObserver>.fromOpaque(info).takeUnretainedValue()
            guard let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            observer.handler(Array(cfPaths.prefix(count)))
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    public func stop() { stopInternal() }

    private func stopInternal() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
#endif
