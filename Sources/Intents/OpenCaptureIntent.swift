import AppIntents
import Foundation

/// Opens Better Workspace ready to capture: the phone's Ingest tab with the keyboard
/// up, or the Mac's quick-capture panel.
///
/// Compiled into both apps and the iPhone widget extension, which needs the type for
/// its Control Center control and widget buttons. It always runs in the app
/// (`openAppWhenRun`); the app picks the request up from `CaptureLaunchRouter`.
struct OpenCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "New Capture"
    static var description = IntentDescription("Opens Better Workspace ready to capture something.",
                                               categoryName: "Capture")
    static var openAppWhenRun = true

    @Parameter(title: "As an idea", default: false)
    var asIdea: Bool

    init() {}

    init(asIdea: Bool) {
        self.asIdea = asIdea
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureLaunchRouter.shared.request(asIdea: asIdea)
        return .result()
    }
}

/// Hands a capture request from an intent to whichever view is listening.
///
/// A request that arrives before the UI exists (the intent launched the app) is kept
/// until something reads it.
@MainActor
final class CaptureLaunchRouter {
    static let shared = CaptureLaunchRouter()
    static let notification = Notification.Name("BetterWorkspaceCaptureLaunchRequest")

    struct Request: Equatable {
        let asIdea: Bool
        let id = UUID()
    }

    private(set) var pending: Request?

    func request(asIdea: Bool) {
        pending = Request(asIdea: asIdea)
        NotificationCenter.default.post(name: Self.notification, object: nil)
    }

    /// The pending request, once.
    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}
