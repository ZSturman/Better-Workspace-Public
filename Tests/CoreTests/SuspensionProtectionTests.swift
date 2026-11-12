import XCTest
@testable import BetterWorkspaceCore

final class SuspensionProtectionTests: XCTestCase {
    func testDeniedActivityDoesNotStartAFileMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SuspensionProtection.withActivity(start: { callback in
            DispatchQueue.global().async { callback(true) }
        }) {
            try Data("must not be written".utf8).write(to: root)
        }) { error in
            XCTAssertTrue(error is SuspensionProtection.Failure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testActivityEndsAfterTheTransactionThrows() {
        enum Expected: Error { case failure }
        let released = expectation(description: "Activity released")
        XCTAssertThrowsError(try SuspensionProtection.withActivity(start: { callback in
            DispatchQueue.global().async { callback(false); released.fulfill() }
        }) { throw Expected.failure })
        wait(for: [released], timeout: 3)
    }

    func testActivityReturnsTheCompletedTransactionValue() throws {
        let released = expectation(description: "Activity released after success")
        let value = try SuspensionProtection.withActivity(start: { callback in
            DispatchQueue.global().async { callback(false); released.fulfill() }
        }) { 42 }
        XCTAssertEqual(value, 42)
        wait(for: [released], timeout: 3)
    }
}
