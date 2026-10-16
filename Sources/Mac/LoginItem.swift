import AppKit
import ServiceManagement
import BetterWorkspaceCore

/// Better Workspace opens at login so its menu bar Ingest is always there.
///
/// The app registers itself (`SMAppService.mainApp`) rather than shipping a second
/// helper app: the menu bar extra, the hotkey panel and the main window already share
/// one process and one model, and macOS lists the app by name under Login Items, where
/// it can be switched off. A login launch keeps the main window closed and the Dock
/// icon hidden (see `AppDelegate`); only the menu bar item appears.
@MainActor
enum LoginItem {
    /// Set once the app has made its one automatic registration. Turning Open at Login
    /// off afterwards is respected: nothing registers it again behind the person's back.
    static let defaultAppliedKey = "loginItemDefaultApplied"

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    /// Registered, but macOS is waiting for approval in System Settings → Login Items.
    static var needsApproval: Bool { status == .requiresApproval }

    /// Only the installed copy may change the login item. The registration is per bundle
    /// identifier, so a development or test build that registered pointed macOS at a
    /// DerivedData copy: it had done exactly that here, and login launched a stale build.
    static func canManage(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        TestIsolation.isActive == false && bundleURL.path.hasPrefix("/Applications/")
    }

    enum ManageError: LocalizedError {
        case notInstalledCopy
        var errorDescription: String? {
            "Open at Login is managed by the copy installed in /Applications, so login opens that app."
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard canManage() else { throw ManageError.notInstalledCopy }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        TestIsolation.defaults.set(true, forKey: defaultAppliedKey)
        TestIsolation.defaults.set(Bundle.main.bundleURL.path, forKey: claimedPathKey)
    }

    /// The installed path that last registered. Absent or different means the record
    /// may name another copy.
    static let claimedPathKey = "loginItemClaimedBundlePath"

    /// Run by the installed copy at every launch. When Open at Login is on but was
    /// registered by another copy (the key says so), register again from here so login
    /// opens this app. Off stays off: an unregistered item is never turned on.
    static func claimForInstalledCopyIfNeeded(bundleURL: URL = Bundle.main.bundleURL) {
        guard canManage(bundleURL: bundleURL), status == .enabled,
              TestIsolation.defaults.string(forKey: claimedPathKey) != bundleURL.path else { return }
        do {
            try SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            TestIsolation.defaults.set(bundleURL.path, forKey: claimedPathKey)
        } catch {
            FileHandle.standardError.write(Data("Open at Login could not be moved to this copy: \(error)\n".utf8))
            // Never leave it off because the second step failed.
            if status != .enabled { try? SMAppService.mainApp.register() }
        }
    }

    /// Registers the installed app the first time it runs. Never from a development
    /// build (a login item would point at DerivedData) or an isolated test run.
    static func registerByDefaultIfNeeded(bundleURL: URL = Bundle.main.bundleURL) {
        guard TestIsolation.isActive == false,
              bundleURL.path.hasPrefix("/Applications/"),
              TestIsolation.defaults.bool(forKey: defaultAppliedKey) == false
        else { return }
        do {
            if status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
            // A failed first registration must be retried at the next launch.
            TestIsolation.defaults.set(true, forKey: defaultAppliedKey)
            TestIsolation.defaults.set(bundleURL.path, forKey: claimedPathKey)
        } catch {
            FileHandle.standardError.write(Data("Open at Login could not be registered: \(error)\n".utf8))
        }
    }

    /// Whether this launch is the one macOS made at login.
    ///
    /// Login Items are opened with `keyAELaunchedAsLogInItem` in the launch event. Read
    /// it in `applicationDidFinishLaunching`, while that event is still current.
    /// `-bwLaunchedAtLogin YES` simulates it for testing.
    static func wasLaunchedAtLogin() -> Bool {
        if UserDefaults.standard.bool(forKey: "bwLaunchedAtLogin") { return true }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              let property = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        else { return false }
        return property.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
