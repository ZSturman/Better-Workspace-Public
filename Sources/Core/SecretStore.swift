import Foundation
import Security

/// Keychain storage for the one secret this app can hold: a Notion integration token.
///
/// It goes in the Keychain rather than preferences because a token in a plist is a
/// token in every backup, every sync and every screen share. The app never logs it,
/// never writes it to its database, and never sends it anywhere but Notion.
///
/// Having no token is the normal state. Better Workspace is complete without one.
public enum SecretStore {

    public static let notionTokenAccount = "notion-integration-token"
    /// A test gets its own service, so it can never read or remove the real token.
    private static let service = TestIsolation.isActive
        ? "com.zacharysturman.BetterWorkspace.isolated-test"
        : "com.zacharysturman.BetterWorkspace"

    public static func save(_ secret: String, account: String = notionTokenAccount) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return remove(account: account) }

        var query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(trimmed.utf8)
        // The token is only ever needed while the app is in use by the person who
        // entered it, so it should not travel and should not survive a wipe.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// `interactive: false` never shows a Keychain access dialog; a headless command
    /// gets nil instead of blocking on a prompt nobody is watching.
    public static func read(account: String = notionTokenAccount, interactive: Bool = true) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8),
              secret.isEmpty == false
        else { return nil }
        return secret
    }

    // Isolated UI previews cannot use credentials or send remote changes. Avoid a
    // synchronous Keychain access prompt while their project view is rendering.
    public static var hasNotionToken: Bool { !TestIsolation.isActive && read() != nil }

    @discardableResult
    public static func remove(account: String = notionTokenAccount) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Enough of the token to recognize which one is stored, and no more.
    public static func fingerprint(account: String = notionTokenAccount) -> String? {
        guard let secret = read(account: account) else { return nil }
        let tail = String(secret.suffix(4))
        return "…\(tail)"
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Which Notion databases to read, remembered between runs.
///
/// Plain identifiers, not secrets, so ordinary preferences are the right place. All
/// optional: an empty id simply means that database is not part of the import.
public struct NotionSettings: Sendable {
    public static let defaultsKey = "notionDatabaseIDs"
    /// The planning databases supplied with this workspace. They fill a missing
    /// preference; an explicitly blank stored value still means "do not import this
    /// database."
    public static let suppliedMilestonesDatabaseID = "304aec944d3c808780acc4b1283f7dd0"
    public static let suppliedFeaturesDatabaseID = "3d3aec944d3c80958968ed04bbe4b570"
    public static let suppliedSocialPostsDatabaseID = "3b0aec944d3c805bb765d28e0ebfccdf"

    public var databases: NotionImport.Databases
    /// Slots nobody has decided yet: never saved, no supplied default. A saved blank is
    /// a decision ("do not import this"), so it is not here. Automatic discovery fills
    /// only these; an explicit "find databases" fills every empty slot.
    public var undecided: Set<String> = []

    static let slotKeys = ["tasks", "milestones", "features", "ideas", "projects", "socialPosts"]

    public init(databases: NotionImport.Databases = .init()) {
        self.databases = databases
    }

    public static func load(from defaults: UserDefaults = TestIsolation.defaults) -> NotionSettings {
        let stored = (defaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        func value(_ key: String) -> String? {
            guard let raw = stored[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  raw.isEmpty == false else { return nil }
            return raw
        }
        var settings = NotionSettings(databases: .init(
            tasks: value("tasks"),
            milestones: value("milestones") ?? (stored["milestones"] == nil ? suppliedMilestonesDatabaseID : nil),
            features: value("features") ?? (stored["features"] == nil ? suppliedFeaturesDatabaseID : nil),
            ideas: value("ideas"), projects: value("projects"),
            socialPosts: value("socialPosts") ?? (stored["socialPosts"] == nil ? suppliedSocialPostsDatabaseID : nil)
        ))
        settings.undecided = Set(slotKeys.filter { stored[$0] == nil && settings.id(for: $0) == nil })
        return settings
    }

    public func save(to defaults: UserDefaults = TestIsolation.defaults) {
        var stored: [String: String] = [:]
        stored["tasks"] = databases.tasks
        stored["milestones"] = databases.milestones
        stored["features"] = databases.features
        stored["ideas"] = databases.ideas
        stored["projects"] = databases.projects
        stored["socialPosts"] = databases.socialPosts
        // Preserve an empty value as an explicit opt-out. Without that sentinel, a
        // person could clear one of the supplied database fields and it would return
        // as a default next time Settings opened.
        for key in Self.slotKeys where stored[key] == nil {
            stored[key] = ""
        }
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    /// A database id from whatever a person pastes: the bare id, with or without
    /// dashes, or the database's URL (`…/304aec944d3c80a882f6fd7ff4d2b607?v=…`).
    public static func databaseID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let path = URL(string: trimmed).map { $0.path.isEmpty ? trimmed : $0.path } ?? trimmed
        // A page URL's last component is "Title-<id>"; the id is its last 32 hex digits.
        for part in path.split(separator: "/").reversed() {
            let compact = part.replacingOccurrences(of: "-", with: "").lowercased()
            let hex = String(compact.suffix(32))
            if hex.count == 32, hex.allSatisfy(\.isHexDigit) { return hex }
        }
        return nil
    }

    /// Fills each empty slot with the shared database whose title names it. A slot
    /// already set is left alone, and an ambiguous title (two databases called
    /// "Tasks") fills nothing, because guessing wrong imports the wrong rows.
    public func filled(from found: [NotionDatabase], onlyUndecided: Bool = false) -> NotionSettings {
        func match(_ names: [String]) -> String? {
            let hits = found.filter { database in
                let title = database.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return names.contains(title)
            }
            return hits.count == 1 ? NotionImport.normalizedID(hits[0].id) : nil
        }
        func fill(_ key: String, _ current: String?, _ names: [String]) -> String? {
            if let current { return current }
            if onlyUndecided && undecided.contains(key) == false { return nil }
            return match(names)
        }
        var copy = self
        copy.databases.tasks = fill("tasks", databases.tasks, ["tasks", "task"])
        copy.databases.milestones = fill("milestones", databases.milestones, ["milestones", "milestone"])
        copy.databases.features = fill("features", databases.features, ["features", "feature"])
        copy.databases.ideas = fill("ideas", databases.ideas, ["ideas", "idea"])
        copy.databases.projects = fill("projects", databases.projects, ["projects", "project"])
        copy.databases.socialPosts = fill("socialPosts", databases.socialPosts, ["social posts", "social post"])
        copy.undecided = undecided.filter { copy.id(for: $0) == nil }
        return copy
    }

    func id(for key: String) -> String? {
        switch key {
        case "tasks": return databases.tasks
        case "milestones": return databases.milestones
        case "features": return databases.features
        case "ideas": return databases.ideas
        case "projects": return databases.projects
        case "socialPosts": return databases.socialPosts
        default: return nil
        }
    }

    public var isConfigured: Bool {
        [databases.tasks, databases.milestones, databases.features, databases.ideas, databases.projects, databases.socialPosts]
            .contains { $0 != nil }
    }
}
