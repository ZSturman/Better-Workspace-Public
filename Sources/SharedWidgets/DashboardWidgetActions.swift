import AppIntents
import WidgetKit
import Foundation
import BetterWorkspaceCore

/// All parameters are assigned by the rendered widget. No prompts or SwiftUI action
/// closures are involved; a persisted confirmation is the second screen.
struct DashboardActionIntent: AppIntent {
    static var title: LocalizedStringResource = "Workspace Widget Action"
    static var isDiscoverable = false
    @Parameter(title: "Action") var action: String
    @Parameter(title: "Target") var target: String
    @Parameter(title: "Scope") var scope: String
    @Parameter(title: "Preview token") var token: String
    @Parameter(title: "Destination") var destination: String
    init() {}
    init(_ action: String, target: String = "", scope: String, token: String = "", destination: String = "") {
        self.action = action; self.target = target; self.scope = scope; self.token = token; self.destination = destination
    }
    func perform() async throws -> some IntentResult {
        guard let store = WidgetCommandStore.shared(appGroup: WidgetDashboardRuntime.appGroup) else { return .result() }
        defer { WidgetCenter.shared.reloadAllTimelines() }
        do {
            try store.clear("error:" + scope)
            let snapshot = DashboardWidgetStore.load(directory: store.directory)
            switch action {
            case "complete":
                if let item = snapshot?.work.first(where: { $0.id == target }), !token.isEmpty,
                   String(item.modifiedAt?.timeIntervalSince1970 ?? 0) != token { throw WidgetCommandError.message("The task changed. Refresh before completing it.") }
                try WidgetDashboardRuntime.complete(taskID: target)
            case "undo":
                guard let id = UUID(uuidString: target) else { throw WidgetCommandError.message("Invalid completion.") }
                try WidgetDashboardRuntime.undo(id: id)
            case "confirm":
                guard let id = UUID(uuidString: token) else { throw WidgetCommandError.message("Invalid confirmation.") }
                if try store.confirmation(scope: scope)?.edit.operation == .fileCapture {
                    try MobileCaptureQueue.confirmWidgetFiling(store: store, scope: scope, token: id)
                } else { try store.confirm(scope: scope, token: id) }
            case "cancel": try store.clear("confirmation:" + scope)
            case "next":
                try store.clear("confirmation:" + scope)
                let current = try store.value("cursor:" + scope, as: Int.self) ?? 0
                try store.set("cursor:" + scope, current + 1)
            case "dismiss":
                if let id = UUID(uuidString: target) { try store.settle([id]) }
            case "refresh": break
            case "file":
                guard let capture = snapshot?.captures.first(where: { $0.name == target }),
                      String(capture.modified.timeIntervalSince1970) == token,
                      snapshot?.destinations.contains(where: { $0.path == destination }) == true else { throw WidgetCommandError.message("The capture or its destination changed. Refresh first.") }
                let edit = MobilePlanningEdit(operation: .fileCapture, title: capture.name, captureFiling: .init(capture: capture, destination: destination))
                try store.stage(scope: scope, edit: edit)
            default:
                guard let item = snapshot?.reviewItems.first(where: { $0.id == target }), item.fingerprint == token else { throw WidgetCommandError.message("The review preview changed. Refresh first.") }
                if action == "snooze" || action == "week" {
                    let until = Calendar.current.date(byAdding: .day, value: action == "week" ? 7 : 1, to: Calendar.current.startOfDay(for: Date()))!
                    try store.append(.planning(.init(operation: .reviewInbox, title: item.title, inboxReview: .init(item: item, action: .snooze, until: until))), coalesce: true)
                } else {
                    guard let decision = OverviewInboxCommand.Action(rawValue: action), decision != .snooze else { throw WidgetCommandError.message("Unknown review action.") }
                    try store.stage(scope: scope, edit: .init(operation: .reviewInbox, title: item.title, inboxReview: .init(item: item, action: decision)))
                }
            }
            // Do not spend the five-minute preview lifetime waiting on connectivity.
            if !["file", "done", "archive", "retire", "cancel", "next", "dismiss"].contains(action) {
                await WidgetDashboardRuntime.refresh(force: true)
            }
        } catch { try? store.set("error:" + scope, error.localizedDescription) }
        return .result()
    }
}
