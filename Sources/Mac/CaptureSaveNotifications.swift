import UserNotifications
import BetterWorkspaceCore

/// Posted only after the idea has reached Ideas, never for a failed or staged draft.
enum CaptureSaveNotifications {
    static func ideaSaved(title: String, originalKept: Bool) {
        guard !TestIsolation.isActive else { return }
        // Share the app's delegate so a foreground save can also show its banner.
        AgentMonitorNotifications.shared.install()
        let content = UNMutableNotificationContent()
        content.title = "Idea saved"
        content.body = "“\(title)” was saved to Ideas."
            + (originalKept ? " Its original copy is still in the Inbox." : "")
        content.threadIdentifier = "idea-captures"
        let request = UNNotificationRequest(identifier: "idea-saved-" + UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            } else if settings.authorizationStatus != .denied {
                center.add(request)
            }
        }
    }
}
