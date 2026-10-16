import Foundation

/// Tag taps the phone has made that the Mac's index may not show yet.
///
/// A refresh replaces the phone's snapshot with what the Mac last published. Until the
/// Mac has applied a tag change and republished, that snapshot still has the old tags,
/// so replacing it wholesale flipped a just-tapped checkmark back — the screen then said
/// the tap had not landed, and people tapped again. Each change is re-applied over a
/// fetched snapshot until the snapshot agrees with it, or it is old enough that the Mac
/// has evidently decided otherwise.
public struct PendingTagChanges: Codable, Equatable, Sendable {
    public static let lifetime: TimeInterval = 120

    struct Change: Codable, Equatable, Sendable {
        let path: String
        let tagID: String
        let isPresent: Bool
        let at: Date
    }

    private var changes: [Change] = []

    public init() {}

    public var isEmpty: Bool { changes.isEmpty }

    /// The latest tap on a tag for a path replaces any earlier one.
    public mutating func record(tagID: String, onPath path: String, isPresent: Bool, now: Date = Date()) {
        changes.removeAll { $0.path == path && $0.tagID == tagID }
        changes.append(Change(path: path, tagID: tagID, isPresent: isPresent, at: now))
    }

    /// Re-applies what the fetched snapshot does not show yet, and forgets changes it
    /// already shows or that have expired.
    public mutating func reconcile(_ snapshot: inout MobileWorkspaceSnapshot, now: Date = Date()) {
        changes.removeAll { change in
            if now.timeIntervalSince(change.at) > Self.lifetime { return true }
            guard let entry = snapshot.entries.first(where: { $0.path == change.path }) else { return false }
            return entry.tagIDs.contains(change.tagID) == change.isPresent
        }
        for change in changes {
            snapshot.setTag(change.tagID, onPath: change.path, isPresent: change.isPresent)
        }
    }
}
