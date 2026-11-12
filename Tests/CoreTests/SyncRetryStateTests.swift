import CloudKit
import XCTest
@testable import BetterWorkspaceCore

final class SyncRetryStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testWaitsDoubleFromThirtySecondsToThirtyMinutes() {
        let waits = (1...9).map { SyncRetryState.delay(afterFailures: $0, retryAfter: nil, random: 0.5) }
        XCTAssertEqual(waits, [30, 60, 120, 240, 480, 960, 1800, 1800, 1800])
    }

    func testJitterStaysWithinTwentyPercent() {
        XCTAssertEqual(SyncRetryState.delay(afterFailures: 3, retryAfter: nil, random: 0), 96, accuracy: 0.001)
        XCTAssertEqual(SyncRetryState.delay(afterFailures: 3, retryAfter: nil, random: 1), 144, accuracy: 0.001)
        XCTAssertEqual(SyncRetryState.delay(afterFailures: 7, retryAfter: nil, random: 1), 2160, accuracy: 0.001)
    }

    func testCloudKitsRequestedWaitIsNeverShortened() {
        let throttled = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 600.0])
        XCTAssertEqual(SyncRetryState.retryAfter(throttled), 600)
        var state = SyncRetryState()
        state.recordFailure(throttled, at: now, random: 0.5)
        XCTAssertEqual(state.nextAttempt, now.addingTimeInterval(600), "Not the 30-second first step")
        XCTAssertNil(SyncRetryState.retryAfter(URLError(.notConnectedToInternet)))
        XCTAssertFalse(SyncRetryState.isPushback(URLError(.notConnectedToInternet)))
        XCTAssertTrue(SyncRetryState.isPushback(CKError(.requestRateLimited)))
    }

    func testAPartialFailuresRetryAfterCounts() {
        let item = CKRecord.ID(recordName: "peer")
        let error = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [item: CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 90.0])]])
        XCTAssertEqual(SyncRetryState.retryAfter(error), 90)
    }

    func testANetworkFailureKeepsTheNormalCadence() {
        var state = SyncRetryState()
        state.recordFailure(URLError(.notConnectedToInternet), at: now, random: 0.5)
        state.recordFailure(CKError(.networkFailure), at: now, random: 0.5)
        XCTAssertTrue(state.isDue(at: now), "Delivery resumes as soon as the device is back online")
        XCTAssertEqual(state.consecutiveFailures, 0)
    }

    func testPeriodicPassesWaitUntilDueAndSuccessResets() {
        var state = SyncRetryState()
        XCTAssertTrue(state.isDue(at: now), "Nothing has failed")
        state.recordFailure(CKError(.serviceUnavailable), at: now, random: 0.5)
        state.recordFailure(CKError(.zoneBusy), at: now, random: 0.5)
        XCTAssertEqual(state.consecutiveFailures, 2)
        XCTAssertFalse(state.isDue(at: now.addingTimeInterval(59)))
        XCTAssertTrue(state.isDue(at: now.addingTimeInterval(60)))
        state.recordSuccess()
        XCTAssertEqual(state, SyncRetryState())
        XCTAssertTrue(state.isDue(at: now))
    }
}
