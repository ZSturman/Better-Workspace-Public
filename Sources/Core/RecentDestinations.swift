import Foundation

/// The few destinations someone actually files into, shown up front; everything else
/// stays one click away in `DestinationOrder`'s stable order.
///
/// `DestinationOrder` deliberately never reorders by use, so a folder's place in the
/// full list can be learned. This is the separate, short "recent" row the capture and
/// filing screens lead with — the full list does not move.
public struct RecentDestinations {
    public static let defaultsKey = "recentFilingDestinations"
    public static let remembered = 12

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = RecentDestinations.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Most recent first.
    public var names: [String] { defaults.stringArray(forKey: key) ?? [] }

    public func record(_ name: String) {
        var names = self.names.filter { $0 != name }
        names.insert(name, at: 0)
        defaults.set(Array(names.prefix(Self.remembered)), forKey: key)
    }

    /// Up to `limit` of `available` (already in `DestinationOrder`): recently used ones
    /// first, then topped up from the front of the stable order, so a new install still
    /// shows its primary folders.
    public func leading<T>(_ available: [T], limit: Int, name: (T) -> String) -> [T] {
        var result: [T] = []
        var taken = Set<String>()
        for recent in names {
            guard result.count < limit, let match = available.first(where: { name($0) == recent }),
                  taken.insert(recent).inserted else { continue }
            result.append(match)
        }
        for item in available where result.count < limit && taken.insert(name(item)).inserted {
            result.append(item)
        }
        return result
    }
}
