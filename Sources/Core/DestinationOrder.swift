import Foundation

/// The order destinations are offered in, in one place.
///
/// Alphabetical put Analytics, Assets and Backups in front of Projects and Ideas,
/// which is precisely backwards for filing something you just captured. Rather than
/// scattering special cases through the UI, ordering lives here: three tiers,
/// alphabetical within each.
///
/// Frequency is deliberately not inferred. A folder's position should be predictable —
/// somewhere you can learn once — not something that quietly rearranges itself. The
/// short "recent" row capture screens lead with is separate (`RecentDestinations`);
/// this full order never moves.
public enum DestinationOrder {

    public enum Tier: Int, Comparable, Sendable {
        /// Where captured things usually belong.
        case primary = 0
        /// Everything else real, including folders this app has never heard of.
        case ordinary = 1
        /// Machinery and archives. Reachable, but rarely the answer.
        case system = 2

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The order the built-in primary destinations appear in. Folders promoted to
    /// primary in their area settings follow these, alphabetically.
    private static let primary: [String] = ["Projects", "Ideas", "To Do"]

    /// The tier a folder falls in with only built-in defaults applied. The real
    /// answer for a discovered folder is its resolved `AreaSettings.ingest`.
    public static func tier(for label: String) -> Tier {
        tier(for: AreaDefaults.configuration(forFolderNamed: label).ingest ?? .ordinary)
    }

    public static func tier(for role: AreaIngestRole) -> Tier {
        switch role {
        case .primary: return .primary
        case .ordinary, .excluded: return .ordinary
        case .system: return .system
        }
    }

    /// Position within the primary tier; everything else sorts alphabetically.
    private static func primaryIndex(_ label: String) -> Int {
        primary.firstIndex(of: label) ?? primary.count
    }

    /// Discovered folders in destination order, leaving out the ones configured not to
    /// be offered.
    public static func destinations(_ folders: [WorkspaceFolder]) -> [WorkspaceFolder] {
        let offered = folders.filter { $0.settings.ingest != .excluded }
        return sorted(offered, label: \.name, tier: { tier(for: $0.settings.ingest) })
    }

    /// Sorts anything that can describe itself with a label.
    public static func sorted<T>(_ items: [T], label: (T) -> String) -> [T] {
        sorted(items, label: label, tier: { tier(for: label($0)) })
    }

    public static func sorted<T>(_ items: [T], label: (T) -> String, tier: (T) -> Tier) -> [T] {
        items.sorted { lhs, rhs in
            let left = label(lhs), right = label(rhs)
            let leftTier = tier(lhs), rightTier = tier(rhs)
            if leftTier != rightTier { return leftTier < rightTier }
            if leftTier == .primary, primaryIndex(left) != primaryIndex(right) {
                return primaryIndex(left) < primaryIndex(right)
            }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }
}
