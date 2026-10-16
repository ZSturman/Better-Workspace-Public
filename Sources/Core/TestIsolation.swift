import Foundation

/// Walls an isolated UI-test launch off from the person's real data.
///
/// UI tests launch the real app. They used to be kept away from real data only by
/// passing fixture paths on the command line, and that was not enough: a test written
/// before those paths existed filed `UITest Idea 43981.md` into the real
/// `~/Workspace/Ideas` and tagged it in the real database. Anything that leaned on a
/// default instead of an argument had the same exposure — the real iCloud inbox,
/// preferences shared with the real app, the Notion token in the Keychain, and CloudKit
/// publishing if sync had been switched on.
///
/// So isolation is decided once, here, and every path to shared state asks. A launch is
/// isolated when it carries `BW_TEST_DATABASE_PATH` (DEBUG builds only, the same switch
/// that already moves the database). In an isolated launch:
///
/// - the Workspace and inbox come only from launch arguments, and fall back to empty
///   folders beside the test database — never `~/Workspace` or iCloud Drive, and never
///   a root the real app remembered in its preferences;
/// - preferences read and write a private suite, not the real app's domain;
/// - the Keychain uses a separate service, so the real token is never read or removed;
/// - CloudKit publishing is off, whatever the real preference says.
public enum TestIsolation {

    public static let environmentKey = "BW_TEST_DATABASE_PATH"

    /// True for a DEBUG build launched by an isolated test.
    public static var isActive: Bool { sandbox != nil }

    /// The directory holding the test database; fallback roots are created inside it.
    public static let sandbox: URL? = {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment[environmentKey], path.isEmpty == false else {
            return nil
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
        #else
        return nil
        #endif
    }()

    /// Where an isolated test's "Move to Trash" goes, instead of the person's Trash.
    public static var trashDirectory: URL? { sandbox?.appendingPathComponent("Trash", isDirectory: true) }

    /// Preferences this app persists. A private suite during a test, so nothing a test
    /// does reaches the real app's preferences — and nothing the real app remembered
    /// (a custom Workspace root, sync switched on) reaches the test.
    public static let defaults: UserDefaults = {
        let name = "com.zacharysturman.BetterWorkspace.isolated-test"
        guard isActive, let sandbox, let suite = UserDefaults(suiteName: name) else {
            return .standard
        }
        // A new sandbox (a new test) starts from nothing; a relaunch in the same one
        // keeps what the last launch saved, so restoring state after a quit is testable.
        if suite.string(forKey: "isolatedSandbox") != sandbox.path {
            suite.removePersistentDomain(forName: name)
            suite.set(sandbox.path, forKey: "isolatedSandbox")
        }
        return suite
    }()

    /// A value given on the command line (`-key value`) and nowhere else.
    ///
    /// `UserDefaults.standard` merges launch arguments with the real app's saved
    /// preferences, so asking it would let a remembered custom root stand in for a
    /// missing argument.
    public static func launchArgument(_ key: String) -> String? {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let value = arguments[key] as? String, value.isEmpty == false else { return nil }
        return value
    }

    /// A launch-argument path, or an empty folder in the sandbox named `fallback`.
    static func root(argument key: String, fallback: String) -> URL? {
        guard let sandbox else { return nil }
        if let path = launchArgument(key) { return URL(fileURLWithPath: path) }
        let url = sandbox.appendingPathComponent(fallback, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
