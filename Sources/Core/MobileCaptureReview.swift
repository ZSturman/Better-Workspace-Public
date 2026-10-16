import Foundation

public struct MobileCaptureReview: Hashable, Codable, Sendable {
    public var capture: DashboardCapture
    public var priority: Int
    public var until: Date?
    public init(capture: DashboardCapture, priority: Int, until: Date?) {
        self.capture = capture; self.priority = priority; self.until = until
    }
}
