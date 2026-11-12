import Foundation

/// Protect short, synchronous shared-container transactions from iOS suspension.
/// Never start a file-lock section when the system has denied or expired its activity.
public enum SuspensionProtection {
    public enum Failure: Error, LocalizedError {
        case unavailable
        public var errorDescription: String? {
            "Keep Better Workspace open to finish safely. Your saved data has been retained."
        }
    }

    public static func run<T>(_ reason: String, _ body: () throws -> T) throws -> T {
        #if os(iOS)
        return try withActivity(start: { callback in
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: callback)
        }, body)
        #else
        return try body()
        #endif
    }

    // The platform callback runs on a concurrent queue. Keep it alive until the
    // synchronous transaction has released every lock, including when it throws.
    static func withActivity<T>(start: (@escaping @Sendable (Bool) -> Void) -> Void,
                                _ body: () throws -> T) throws -> T {
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let state = State()
        start { expired in
            guard state.claimFirstCall(expired: expired) else { return }
            started.signal()
            if !expired { finished.wait() }
        }
        started.wait()
        defer { finished.signal() }
        guard !state.isExpired else { throw Failure.unavailable }
        return try body()
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var called = false
        private var expired = false
        var isExpired: Bool {
            lock.lock(); defer { lock.unlock() }
            return expired
        }
        func claimFirstCall(expired: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            self.expired = self.expired || expired
            guard !called else { return false }
            called = true
            return true
        }
    }
}
