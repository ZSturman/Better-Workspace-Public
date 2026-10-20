import Foundation

/// How a typed tag name finds the tags that already exist.
///
/// Shared by the Mac tag editor and the phone's capture composer so both rank the same
/// way. The point is to make picking an existing tag the easy path and creating a
/// near-duplicate ("project" beside "Projects") the deliberate one.
public enum TagMatching {
    public static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = compact(normalized(lhs)), right = compact(normalized(rhs))
        return !left.isEmpty && (left == right || singular(left) == singular(right))
    }

    /// Folds case, diacritics and separators: "Machine-Learning", "machine learning"
    /// and "Machine_Learning" are one name.
    public static func normalized(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: nil)
        return folded
            .split(whereSeparator: { $0.isWhitespace || "-_/.".contains($0) })
            .joined(separator: " ")
    }

    /// `normalized` with the spaces gone, so word breaks do not count either:
    /// "RaspberryPi", "Raspberry Pi" and "raspberry-pi" are one name.
    static func compact(_ normalized: String) -> String {
        normalized.replacingOccurrences(of: " ", with: "")
    }

    /// A trailing plural "s" is dropped so "Project" finds "Projects". Short words and
    /// "-ss" endings are left alone ("Bus", "Class").
    static func singular(_ normalized: String) -> String {
        guard normalized.count > 3, normalized.hasSuffix("s"), normalized.hasSuffix("ss") == false else {
            return normalized
        }
        return String(normalized.dropLast())
    }

    /// An existing tag that is the same name as `query` in all but spelling details —
    /// case, accents, separators, spacing, a plural "s". Creating `query` instead would
    /// make a duplicate.
    public static func equivalent(to query: String, in tags: [Tag]) -> Tag? {
        let key = compact(normalized(query))
        guard key.isEmpty == false else { return nil }
        if let exact = tags.first(where: { compact(normalized($0.name)) == key }) { return exact }
        let singularKey = singular(key)
        return tags.first { singular(compact(normalized($0.name))) == singularKey }
    }

    /// How well `name` answers `query`, lower is better; `nil` is no match.
    /// Prefix and containment ignore spacing, so "raspberryp" still finds "Raspberry Pi".
    static func score(_ name: String, query key: String) -> Int? {
        let candidate = normalized(name)
        let compactCandidate = compact(candidate), compactKey = compact(key)
        if compactCandidate == compactKey || singular(compactCandidate) == singular(compactKey) { return 0 }
        if compactCandidate.hasPrefix(compactKey) { return 1 }
        if candidate.split(separator: " ").contains(where: { $0.hasPrefix(key) }) { return 2 }
        if compactCandidate.contains(compactKey) { return 3 }
        return nil
    }

    /// Tags matching `query`, best first: the same name, then names that start with it,
    /// then names with a word that starts with it, then names that merely contain it.
    /// An empty query answers every tag alphabetically.
    public static func ranked(_ query: String, in tags: [Tag]) -> [Tag] {
        let key = normalized(query)
        let alphabetical: (Tag, Tag) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard key.isEmpty == false else { return tags.sorted(by: alphabetical) }
        return tags
            .compactMap { tag in score(tag.name, query: key).map { (tag, $0) } }
            .sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 < rhs.1 : alphabetical(lhs.0, rhs.0) }
            .map(\.0)
    }

    /// What pressing Return in a tag field should do.
    public enum Resolution: Equatable, Sendable {
        /// Use this tag that already exists.
        case existing(Tag)
        /// Nothing close exists; make a new tag with this (trimmed) name.
        case create(String)
        case nothing
    }

    /// Return prefers an existing tag: the same name, or the best tag that starts with
    /// what was typed ("pro" → "Programming"). A tag that only contains the text
    /// somewhere in the middle is not a good enough match to stand in for a new name.
    /// Creating a tag that is merely a prefix of another stays one explicit tap away.
    public static func resolve(_ query: String, in tags: [Tag]) -> Resolution {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return .nothing }
        if let same = equivalent(to: trimmed, in: tags) { return .existing(same) }
        let key = normalized(trimmed)
        if let best = ranked(trimmed, in: tags).first, let score = score(best.name, query: key), score <= 2 {
            return .existing(best)
        }
        return .create(trimmed)
    }
}
