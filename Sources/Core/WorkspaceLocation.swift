import Foundation

/// Resolves the on-disk locations this app reads from and (for ingest only) writes to.
///
/// Everything path-shaped in the app funnels through here so that no view invents its
/// own idea of where the workspace lives.
public struct WorkspaceLocation: Sendable {

    public static let defaultsWorkspaceRootKey = "workspaceRootPath"
    public static let defaultsIngestRootKey = "ingestRootPath"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `~/Workspace`, unless overridden in preferences.
    public static var resolved: WorkspaceLocation {
        // A test never falls through to the real Workspace. See `TestIsolation`.
        if let isolated = TestIsolation.root(argument: defaultsWorkspaceRootKey, fallback: "Workspace") {
            return WorkspaceLocation(root: isolated)
        }
        if let custom = UserDefaults.standard.string(forKey: defaultsWorkspaceRootKey),
           custom.isEmpty == false {
            return WorkspaceLocation(root: URL(fileURLWithPath: custom))
        }
        return WorkspaceLocation(root: defaultRoot)
    }

    public static var defaultRoot: URL {
        homeDirectory.appendingPathComponent("Workspace")
    }

    /// `homeDirectoryForCurrentUser` is macOS-only; the iOS companion never browses a
    /// Workspace, but the type still has to compile there.
    public static var homeDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public func url(for area: WorkspaceArea) -> URL {
        url(forArea: area.directoryName)
    }

    /// The folder for an area named by its directory — any area, purpose-built or not.
    public func url(forArea folderName: String) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    public func exists(_ area: WorkspaceArea) -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: url(for: area).path, isDirectory: &isDir)
        return ok && isDir.boolValue
    }

    /// The area a URL belongs to: the name of the top-level Workspace folder it sits in,
    /// or nil for the root itself and anything outside it. Purely lexical, so it also
    /// answers for a folder created a moment ago that discovery has not seen yet.
    public func areaName(containing url: URL) -> String? {
        let rootPath = root.canonicalPath
        let path = url.canonicalPath
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let first = path.dropFirst(rootPath.count + 1).split(separator: "/", maxSplits: 1).first
        return first.map(String.init)
    }

    /// The purpose-built area a URL belongs to, if its folder has one.
    public func area(containing url: URL) -> WorkspaceArea? {
        areaName(containing: url).flatMap(WorkspaceArea.init(folderName:))
    }
}

/// Resolves where unprocessed ingest items physically live.
///
/// Preference order, highest first:
///  1. A path the user configured in Preferences.
///  2. This app's iCloud ubiquity container, when one is provisioned.
///  3. `iCloud Drive/Better Workspace/Inbox` — a plain folder in the generic iCloud
///     Drive container. Reachable from macOS by path and from iOS via a security-scoped
///     bookmark obtained once through the document picker. No entitlement required.
///  4. `~/Better Workspace Ingest/Inbox` — local-only fallback.
///
/// Deliberately *not* inside `~/Workspace`: ingest is not a tenth organized area.
public struct IngestLocation: Sendable {

    public static let ubiquityContainerID = "iCloud.com.zacharysturman.BetterWorkspace"
    public static let folderName = "Better Workspace"
    public static let inboxName = "Inbox"

    public enum Backing: String, Sendable {
        case userConfigured
        case ubiquityContainer
        case iCloudDrive
        case local
    }

    public let inbox: URL
    public let backing: Backing

    public init(inbox: URL, backing: Backing) {
        self.inbox = inbox.standardizedFileURL
        self.backing = backing
    }

    public var syncsWithMobile: Bool {
        backing == .ubiquityContainer || backing == .iCloudDrive
    }

    public var backingDescription: String {
        switch backing {
        case .userConfigured: return "Custom folder"
        case .ubiquityContainer: return "iCloud app container"
        case .iCloudDrive: return "iCloud Drive"
        case .local: return "Local folder (not synced)"
        }
    }

    /// A location good enough to construct the app with, chosen without touching the
    /// filesystem.
    ///
    /// Every `stat` against `~/Library/Mobile Documents` is a file-provider round trip,
    /// and doing one while building the app model stalls launch badly enough that no
    /// window appears. Callers start here and then swap in `resolve()` off the main
    /// thread once the app is up.
    public static func provisional(defaults: UserDefaults = .standard) -> IngestLocation {
        if let isolated = TestIsolation.root(argument: WorkspaceLocation.defaultsIngestRootKey, fallback: "Inbox") {
            return IngestLocation(inbox: isolated, backing: .userConfigured)
        }
        if let custom = defaults.string(forKey: WorkspaceLocation.defaultsIngestRootKey),
           custom.isEmpty == false {
            return IngestLocation(inbox: URL(fileURLWithPath: custom), backing: .userConfigured)
        }
        return IngestLocation(
            inbox: WorkspaceLocation.homeDirectory
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
                .appendingPathComponent(inboxName, isDirectory: true),
            backing: .iCloudDrive
        )
    }

    /// Full resolution. Touches the filesystem, so never call this on the main thread.
    public static func resolve(defaults: UserDefaults = .standard) -> IngestLocation {
        if let isolated = TestIsolation.root(argument: WorkspaceLocation.defaultsIngestRootKey, fallback: "Inbox") {
            return IngestLocation(inbox: isolated, backing: .userConfigured)
        }
        if let custom = defaults.string(forKey: WorkspaceLocation.defaultsIngestRootKey),
           custom.isEmpty == false {
            return IngestLocation(inbox: URL(fileURLWithPath: custom), backing: .userConfigured)
        }
        #if os(iOS)
        // iOS has no path into iCloud Drive without either a container or a
        // security-scoped bookmark, so the container is worth the cost there.
        //
        // Deliberately *not* done on macOS: `url(forUbiquityContainerIdentifier:)` can
        // block for a long time, and calling it from `AppModel.init` stalled the main
        // thread hard enough that the window never appeared. The Mac reaches the same
        // folder by plain path below, so it gains nothing from asking.
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: ubiquityContainerID) {
            let inbox = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(inboxName, isDirectory: true)
            return IngestLocation(inbox: inbox, backing: .ubiquityContainer)
        }
        #endif
        // The iOS companion writes into its own ubiquity container. On the Mac that
        // container is just a folder, readable by path with no entitlement and without
        // the blocking `url(forUbiquityContainerIdentifier:)` call.
        let mobileDocuments = WorkspaceLocation.homeDirectory
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let appContainer = mobileDocuments
            .appendingPathComponent(ubiquityContainerID.replacingOccurrences(of: ".", with: "~"),
                                    isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        if FileManager.default.fileExists(atPath: appContainer.path) {
            return IngestLocation(inbox: appContainer.appendingPathComponent(inboxName, isDirectory: true),
                                  backing: .ubiquityContainer)
        }

        let cloudDocs = mobileDocuments
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: cloudDocs.path) {
            let inbox = cloudDocs
                .appendingPathComponent(folderName, isDirectory: true)
                .appendingPathComponent(inboxName, isDirectory: true)
            return IngestLocation(inbox: inbox, backing: .iCloudDrive)
        }
        let local = WorkspaceLocation.homeDirectory
            .appendingPathComponent("\(folderName) Ingest", isDirectory: true)
            .appendingPathComponent(inboxName, isDirectory: true)
        return IngestLocation(inbox: local, backing: .local)
    }

    /// Registers this app as a user of the shared iCloud container.
    ///
    /// macOS reaches the inbox by plain path, which is fast and needs no round trip —
    /// but a process that only reads that path is invisible to the sync machinery.
    /// Nothing tells the system the container is in use, and it stops being kept
    /// current: captures made on the phone stay on the phone, files written on the Mac
    /// never leave it, and neither side shows an error because each one can still read
    /// its own copy perfectly well. Asking for the container once is what registers it.
    ///
    /// Deliberately returns nothing and is never awaited on a launch path:
    /// `url(forUbiquityContainerIdentifier:)` can block for seconds, which is why
    /// `resolve()` still picks the location by path.
    public static func registerUbiquityContainer(identifier: String = ubiquityContainerID) {
        _ = FileManager.default.url(forUbiquityContainerIdentifier: identifier)
    }

    /// Creates the inbox directory if needed. This is the only directory this app
    /// creates outside of an explicit user-confirmed classification move.
    @discardableResult
    public func ensureExists() -> Bool {
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
