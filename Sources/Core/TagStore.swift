import Foundation

public struct Tag: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var name: String
    public var colorIndex: Int
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, colorIndex: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.createdAt = createdAt
    }

    /// Stable colour derived from the name, so `AI` looks the same everywhere it appears.
    public static func colorIndex(for name: String) -> Int {
        let normalized = name.lowercased()
        var hash: UInt64 = 5381
        for byte in normalized.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Int(hash % 8)
    }
}

/// A filesystem object as this app remembers it: an identity, a last-known path, and
/// whatever this app has attached to it.
public struct TaggedObject: Sendable, Hashable {
    public let identityKey: String
    public var lastPath: String
    public var displayName: String
    public var area: String?
    public var updatedAt: Date
}

/// The single central tag repository.
///
/// There is exactly one of these for the whole app. A tag named `AI` is the same row
/// whether it is attached to an Idea, a Project, a Reference, an Inspiration image or
/// an item still sitting in the ingest inbox.
public final class TagStore: @unchecked Sendable {

    private let db: Database
    private let lock = NSLock()

    public init(database: Database) {
        self.db = database
    }

    // MARK: - Object identity

    /// Finds or creates this app's record for a filesystem object.
    ///
    /// Resolution order, which is what makes tags survive both external renames and
    /// identity changes:
    ///  1. Match on the current inode. If the path moved, update the stored path.
    ///  2. Otherwise match on the last-known path, and *rebind* the record to the
    ///     current inode — this covers a move that did not preserve the inode.
    ///  3. Otherwise create a new record.
    @discardableResult
    public func registerObject(url: URL, area: String? = nil) -> TaggedObject {
        lock.lock(); defer { lock.unlock() }
        let path = url.canonicalPath
        let name = url.lastPathComponent
        let now = Date()
        let identity = FileIdentityResolver.identity(of: url)
        let key = identity?.key ?? "path:" + path

        if let existing = fetchObject(identityKey: key) {
            if existing.lastPath != path || existing.area != area {
                _ = try? db.run(
                    "UPDATE objects SET last_path = ?, display_name = ?, area = ?, updated_at = ? WHERE identity_key = ?",
                    [.text(path), .text(name), area.map { .text($0) } ?? .null,
                     .double(now.timeIntervalSince1970), .text(key)]
                )
            }
            var updated = existing
            updated.lastPath = path
            updated.displayName = name
            updated.area = area
            return updated
        }

        if let byPath = fetchObject(path: path), byPath.identityKey != key {
            // Same path, different inode: rebind so assignments follow.
            _ = try? db.run(
                "UPDATE objects SET identity_key = ?, display_name = ?, area = ?, updated_at = ? WHERE identity_key = ?",
                [.text(key), .text(name), area.map { .text($0) } ?? .null,
                 .double(now.timeIntervalSince1970), .text(byPath.identityKey)]
            )
            return TaggedObject(identityKey: key, lastPath: path, displayName: name,
                                area: area, updatedAt: now)
        }

        _ = try? db.run(
            "INSERT OR IGNORE INTO objects (identity_key, last_path, display_name, area, updated_at) VALUES (?,?,?,?,?)",
            [.text(key), .text(path), .text(name), area.map { .text($0) } ?? .null,
             .double(now.timeIntervalSince1970)]
        )
        return TaggedObject(identityKey: key, lastPath: path, displayName: name,
                            area: area, updatedAt: now)
    }

    /// Moves this app's record for an object from one location to another.
    ///
    /// Called by `IngestService` immediately after a classification move. The record is
    /// looked up by its *pre-move* identity and rewritten to the post-move identity, so
    /// tag assignments survive whether or not the inode was preserved.
    public func rebindObject(fromIdentityKey oldKey: String, to newURL: URL, area: String?) {
        lock.lock(); defer { lock.unlock() }
        let path = newURL.canonicalPath
        let name = newURL.lastPathComponent
        let newKey = FileIdentityResolver.identity(of: newURL)?.key ?? "path:" + path
        let now = Date().timeIntervalSince1970

        guard fetchObject(identityKey: oldKey) != nil else {
            _ = try? db.run(
                "INSERT OR IGNORE INTO objects (identity_key, last_path, display_name, area, updated_at) VALUES (?,?,?,?,?)",
                [.text(newKey), .text(path), .text(name), area.map { .text($0) } ?? .null, .double(now)]
            )
            return
        }

        if newKey == oldKey {
            _ = try? db.run(
                "UPDATE objects SET last_path = ?, display_name = ?, area = ?, updated_at = ? WHERE identity_key = ?",
                [.text(path), .text(name), area.map { .text($0) } ?? .null, .double(now), .text(oldKey)]
            )
            return
        }

        // Inode changed. Carry the assignments across by hand, then drop the old row.
        _ = try? db.run(
            "INSERT OR IGNORE INTO objects (identity_key, last_path, display_name, area, updated_at) VALUES (?,?,?,?,?)",
            [.text(newKey), .text(path), .text(name), area.map { .text($0) } ?? .null, .double(now)]
        )
        _ = try? db.run(
            "INSERT OR IGNORE INTO assignments (object_key, tag_id, created_at) SELECT ?, tag_id, created_at FROM assignments WHERE object_key = ?",
            [.text(newKey), .text(oldKey)]
        )
        _ = try? db.run("DELETE FROM objects WHERE identity_key = ?", [.text(oldKey)])
    }

    /// Updates only this app's known tag paths after an opaque same-volume folder move.
    /// No traversal or filesystem inspection is required, including for nested tags.
    public func rebindKnownPaths(from source: URL, to destination: URL, area: String) throws {
        let old = source.canonicalPath, new = destination.canonicalPath
        let prefix = old + "/"
        try db.run("UPDATE objects SET last_path = ? || substr(last_path, length(?) + 1), area = ?, updated_at = ? WHERE last_path = ? OR substr(last_path, 1, length(?)) = ?",
            [.text(new), .text(old), .text(area), .double(Date().timeIntervalSince1970), .text(old), .text(prefix), .text(prefix)])
    }

    public func identityKey(for url: URL) -> String {
        if let identity = FileIdentityResolver.identity(of: url) { return identity.key }
        return "path:" + url.canonicalPath
    }

    private func fetchObject(identityKey: String) -> TaggedObject? {
        (try? db.query(
            "SELECT identity_key, last_path, display_name, area, updated_at FROM objects WHERE identity_key = ?",
            [.text(identityKey)], row: Self.makeObject
        ))?.first
    }

    private func fetchObject(path: String) -> TaggedObject? {
        (try? db.query(
            "SELECT identity_key, last_path, display_name, area, updated_at FROM objects WHERE last_path = ?",
            [.text(path)], row: Self.makeObject
        ))?.first
    }

    private static func makeObject(_ r: Database.Row) -> TaggedObject {
        TaggedObject(identityKey: r.string(0), lastPath: r.string(1), displayName: r.string(2),
                     area: r.optionalString(3), updatedAt: r.date(4))
    }

    // MARK: - Tags

    public func allTags() -> [Tag] {
        (try? db.query("SELECT id, name, color_index, created_at FROM tags ORDER BY name COLLATE NOCASE", row: {
            Tag(id: $0.string(0), name: $0.string(1), colorIndex: Int($0.int(2)), createdAt: $0.date(3))
        })) ?? []
    }

    /// How many *existing* files carry each tag.
    ///
    /// Records for files that have since been deleted are kept — the tag browser shows
    /// them as missing so nothing disappears silently — but they are not counted, because
    /// a sidebar badge saying 5 when only 3 of them exist is a lie.
    public func tagUsageCounts() -> [String: Int] {
        let rows = (try? db.query(
            "SELECT a.tag_id, o.last_path FROM assignments a JOIN objects o ON o.identity_key = a.object_key",
            row: { ($0.string(0), $0.string(1)) }
        )) ?? []
        var counts: [String: Int] = [:]
        var known: [String: Bool] = [:]
        for (tag, path) in rows {
            let exists = known[path] ?? FileManager.default.fileExists(atPath: path)
            known[path] = exists
            if exists { counts[tag, default: 0] += 1 }
        }
        return counts
    }

    /// Objects carrying this tag whose file is gone.
    public func missingObjects(withTagID tagID: String) -> [TaggedObject] {
        objects(withTagID: tagID).filter { FileManager.default.fileExists(atPath: $0.lastPath) == false }
    }

    /// Drops this app's records for files carrying `tagID` that no longer exist.
    ///
    /// Explicit, never automatic: an item moved in Finder should not lose its tags just
    /// because the app happened to relaunch before noticing.
    @discardableResult
    public func forgetMissingObjects(withTagID tagID: String) -> Int {
        let gone = missingObjects(withTagID: tagID)
        for object in gone {
            _ = try? db.run("DELETE FROM assignments WHERE object_key = ?", [.text(object.identityKey)])
            _ = try? db.run("DELETE FROM objects WHERE identity_key = ?", [.text(object.identityKey)])
        }
        return gone.count
    }

    public func tag(named name: String) -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? db.query(
            "SELECT id, name, color_index, created_at FROM tags WHERE name = ? COLLATE NOCASE",
            [.text(trimmed)],
            row: { Tag(id: $0.string(0), name: $0.string(1), colorIndex: Int($0.int(2)), createdAt: $0.date(3)) }
        ))?.first
    }

    /// The tag that already has this name in all but spelling details (`TagMatching`):
    /// `AI` and `ai`, `Raspberry Pi` and `RaspberryPi`.
    public func existingTag(equivalentTo name: String) -> Tag? {
        tag(named: name) ?? TagMatching.equivalent(to: name, in: allTags())
    }

    /// Creates a tag, or returns the existing one with that name. Names are compared
    /// as `TagMatching` compares them, so `AI` and `ai`, or `Raspberry Pi` and
    /// `raspberry pi`, never diverge, whichever field or sync they were typed into.
    @discardableResult
    public func createTag(named name: String) -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let existing = existingTag(equivalentTo: trimmed) { return existing }
        let created = Tag(name: trimmed, colorIndex: Tag.colorIndex(for: trimmed))
        _ = try? db.run(
            "INSERT INTO tags (id, name, color_index, created_at) VALUES (?,?,?,?)",
            [.text(created.id), .text(created.name), .int(Int64(created.colorIndex)),
             .double(created.createdAt.timeIntervalSince1970)]
        )
        return tag(named: trimmed) ?? created
    }

    /// Imports the exact tag identity generated by the phone. The name stays unique
    /// in the same sense as tags created on the Mac: an equivalent tag already here is
    /// answered instead, with its own id.
    @discardableResult
    public func createTag(_ tag: Tag) -> Tag? {
        let trimmed = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let existing = existingTag(equivalentTo: trimmed) { return existing }
        _ = try? db.run(
            "INSERT INTO tags (id, name, color_index, created_at) VALUES (?,?,?,?)",
            [.text(tag.id), .text(trimmed), .int(Int64(tag.colorIndex)),
             .double(tag.createdAt.timeIntervalSince1970)]
        )
        return self.tag(named: trimmed)
    }

    /// Refuses a name that another tag already has in all but spelling details;
    /// re-casing a tag's own name ("raspberry pi" → "Raspberry Pi") is fine.
    public func renameTag(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              TagMatching.equivalent(to: trimmed, in: allTags().filter { $0.id != id }) == nil
        else { return }
        _ = try? db.run("UPDATE tags SET name = ?, color_index = ? WHERE id = ?",
                    [.text(trimmed), .int(Int64(Tag.colorIndex(for: trimmed))), .text(id)])
    }

    public func deleteTag(id: String) {
        _ = try? db.run("DELETE FROM tags WHERE id = ?", [.text(id)])
    }

    // MARK: - Assignments

    public func tags(for url: URL, area: String? = nil) -> [Tag] {
        let key = identityKey(for: url)
        let byIdentity = tags(forObjectKey: key)
        if byIdentity.isEmpty == false { return byIdentity }
        // Fall back to the last-known path: covers an object whose inode changed
        // underneath us without this app being told.
        if let byPath = fetchObject(path: url.canonicalPath), byPath.identityKey != key {
            let found = tags(forObjectKey: byPath.identityKey)
            // Adopt the file's current identity while the path still connects the two.
            // Most editors save by renaming a new file over the old one, so the inode
            // changes on every save; answering by path and leaving the record on the old
            // inode meant the next Finder rename — new path, unknown inode — lost the
            // tags for good.
            if found.isEmpty == false, key.hasPrefix("path:") == false {
                rebindObject(fromIdentityKey: byPath.identityKey, to: url, area: area ?? byPath.area)
            }
            return found
        }
        return []
    }

    public func tags(forObjectKey key: String) -> [Tag] {
        (try? db.query("""
            SELECT t.id, t.name, t.color_index, t.created_at
            FROM assignments a JOIN tags t ON t.id = a.tag_id
            WHERE a.object_key = ?
            ORDER BY t.name COLLATE NOCASE
            """, [.text(key)],
            row: { Tag(id: $0.string(0), name: $0.string(1), colorIndex: Int($0.int(2)), createdAt: $0.date(3)) }
        )) ?? []
    }

    public func assign(tagID: String, to url: URL, area: String?) {
        let object = registerObject(url: url, area: area)
        _ = try? db.run(
            "INSERT OR IGNORE INTO assignments (object_key, tag_id, created_at) VALUES (?,?,?)",
            [.text(object.identityKey), .text(tagID), .double(Date().timeIntervalSince1970)]
        )
    }

    public func unassign(tagID: String, from url: URL) {
        let key = identityKey(for: url)
        _ = try? db.run("DELETE FROM assignments WHERE object_key = ? AND tag_id = ?", [.text(key), .text(tagID)])
        if let byPath = fetchObject(path: url.canonicalPath), byPath.identityKey != key {
            _ = try? db.run("DELETE FROM assignments WHERE object_key = ? AND tag_id = ?",
                        [.text(byPath.identityKey), .text(tagID)])
        }
    }

    /// All object records carrying a tag — used to answer "where is everything tagged AI?"
    public func objects(withTagID tagID: String) -> [TaggedObject] {
        (try? db.query("""
            SELECT o.identity_key, o.last_path, o.display_name, o.area, o.updated_at
            FROM assignments a JOIN objects o ON o.identity_key = a.object_key
            WHERE a.tag_id = ?
            ORDER BY o.display_name COLLATE NOCASE
            """, [.text(tagID)], row: Self.makeObject)) ?? []
    }

    /// Bulk lookup so a list of 386 projects does not issue 386 queries.
    public func tagsByObjectKey(forPaths paths: [String]) -> [String: [Tag]] {
        guard paths.isEmpty == false else { return [:] }
        let rows = (try? db.query("""
            SELECT o.identity_key, o.last_path, t.id, t.name, t.color_index, t.created_at
            FROM objects o
            JOIN assignments a ON a.object_key = o.identity_key
            JOIN tags t ON t.id = a.tag_id
            """, row: { r -> (String, String, Tag) in
                (r.string(0), r.string(1),
                 Tag(id: r.string(2), name: r.string(3), colorIndex: Int(r.int(4)), createdAt: r.date(5)))
            })) ?? []

        let wanted = Set(paths)
        var out: [String: [Tag]] = [:]
        for (_, path, tag) in rows where wanted.contains(path) {
            out[path, default: []].append(tag)
        }
        for key in out.keys {
            out[key]?.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return out
    }

    /// Drops records whose last known path no longer exists. Only touches this app's
    /// private database; never the filesystem.
    ///
    /// Nothing calls this automatically, and that is the point: a file moved in Finder
    /// also has a path that no longer exists, and there is no way to ask whether its
    /// inode is still alive without a path to ask about. `tags(for:)` recovers such an
    /// object by identity on the next sighting, so leaving the record is always the
    /// safer default. `forgetMissingObjects(withTagID:)` is the explicit, user-driven
    /// version and is what the UI uses.
    public func pruneMissingObjects() -> Int {
        let all = (try? db.query(
            "SELECT identity_key, last_path, display_name, area, updated_at FROM objects",
            row: Self.makeObject
        )) ?? []
        var removed = 0
        for object in all where FileManager.default.fileExists(atPath: object.lastPath) == false {
            _ = try? db.run("DELETE FROM objects WHERE identity_key = ?", [.text(object.identityKey)])
            removed += 1
        }
        return removed
    }
}
