import CloudKit
import Foundation

/// When a device may try routine synchronization again after iCloud pushed back.
///
/// Periodic passes used to retry every 25–30 seconds whatever the failure, including while
/// iCloud was throttling (`requestRateLimited`, `zoneBusy`, `serviceUnavailable`) and asking
/// for a wait. Now each consecutive pushback doubles the wait from 30 seconds up to 30
/// minutes, spread by ±20% so devices do not retry in step, and never shorter than
/// CloudKit's `retryAfterSeconds`. A plain network failure is not pushback: it keeps the
/// normal cadence, so delivery resumes as soon as the device is back online (October 29
/// device QA: backing off on an iPhone's flaky Wi-Fi held its changes for five minutes).
/// Explicit opportunities (launch, foreground, wake, a save, Synchronize now, leaving the
/// app) always try at once; only the periodic timer waits. A success resets everything.
public struct SyncRetryState: Sendable, Equatable {
    public static let base: TimeInterval = 30
    public static let cap: TimeInterval = 1_800
    public static let jitter = 0.2

    public private(set) var consecutiveFailures = 0
    public private(set) var nextAttempt: Date?

    public init() {}

    /// The wait after `failures` consecutive failures; `random` is in 0...1.
    public static func delay(afterFailures failures: Int, retryAfter: TimeInterval?, random: Double) -> TimeInterval {
        let exponential = min(cap, base * pow(2, Double(max(failures - 1, 0))))
        let spread = exponential * (1 + jitter * (2 * min(max(random, 0), 1) - 1))
        return max(spread, retryAfter ?? 0)
    }

    /// CloudKit's own requested wait, from the error or any of its partial errors.
    public static func retryAfter(_ error: Error) -> TimeInterval? {
        guard let error = error as? CKError else { return nil }
        let partial = error.partialErrorsByItemID?.values.compactMap { ($0 as? CKError)?.retryAfterSeconds } ?? []
        return ([error.retryAfterSeconds].compactMap { $0 } + partial).max()
    }

    /// iCloud asked this device to slow down, by error code or a requested wait.
    public static func isPushback(_ error: Error) -> Bool {
        if retryAfter(error) != nil { return true }
        guard let error = error as? CKError else { return false }
        let codes: Set<CKError.Code> = [.requestRateLimited, .zoneBusy, .serviceUnavailable]
        if codes.contains(error.code) { return true }
        return error.partialErrorsByItemID?.values.contains { ($0 as? CKError).map { codes.contains($0.code) } ?? false } ?? false
    }

    public mutating func recordFailure(_ error: Error, at now: Date = Date(), random: Double = .random(in: 0...1)) {
        guard Self.isPushback(error) else { recordSuccess(); return }
        consecutiveFailures += 1
        nextAttempt = now.addingTimeInterval(Self.delay(afterFailures: consecutiveFailures, retryAfter: Self.retryAfter(error), random: random))
    }

    public mutating func recordSuccess() { consecutiveFailures = 0; nextAttempt = nil }

    public func isDue(at now: Date = Date()) -> Bool { nextAttempt.map { $0 <= now } ?? true }
}
