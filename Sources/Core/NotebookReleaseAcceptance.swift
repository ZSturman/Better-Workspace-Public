import Foundation

/// A bounded, explicit launch mode for testing the actual signed app. No arbitrary
/// paths, personal stores, filesystem indexing, app groups or Mac command queues.
public enum NotebookReleaseAcceptance {
    public static var sessionID: UUID? {
        TestIsolation.launchArgument("BWNotebookAcceptance").flatMap(UUID.init(uuidString:))
    }

    /// Empty in-memory root for Release UI/screenshot tests. Connected models and
    /// the person's personal/cloud stores must not be constructed in this mode.
    public static var previewSessionID: UUID? {
        TestIsolation.launchArgument("BWPersonalPreviewIsolation").flatMap(UUID.init(uuidString:))
    }

    public static var isSamplePreview: Bool {
        previewSessionID != nil && TestIsolation.launchArgument("BWPersonalPreviewContent") == "sample"
    }

    public static var isBackendTest: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BW_RUN_NOTEBOOK_CLOUD_ACCEPTANCE"] == "1"
        #else
        false
        #endif
    }

    public static var isActive: Bool { sessionID != nil || previewSessionID != nil || isBackendTest }

    public static func taskID(for session: UUID) -> UUID {
        var bytes = session.uuid
        bytes.15 ^= 1
        return UUID(uuid: bytes)
    }

    public static func storeURL(for session: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterWorkspace/ReleaseAcceptance", isDirectory: true)
            .appendingPathComponent(session.uuidString, isDirectory: true)
            .appendingPathComponent("Notebook.store")
    }
}
