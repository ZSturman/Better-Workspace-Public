import Foundation

public enum Format {

    public static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "—" }
        return byteFormatter.string(fromByteCount: value)
    }

    public static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// "42m", "1h 05m" — a session's length at a glance.
    public static func duration(seconds: Double) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    public static func shortDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return shortFormatter.string(from: date)
    }

    public static func count(_ value: Int?, singular: String, plural: String? = nil) -> String {
        guard let value else { return "—" }
        let word = value == 1 ? singular : (plural ?? singular + "s")
        return "\(value) \(word)"
    }

    /// Bucket a date into a coarse age band — the axis that makes the Organize
    /// backlog legible (its items span 2022-12 to now).
    public static func ageBand(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case ..<7: return "This week"
        case ..<31: return "This month"
        case ..<93: return "Last 3 months"
        case ..<366: return "This year"
        case ..<731: return "1–2 years"
        default: return "Over 2 years"
        }
    }

    public static let ageBandOrder = ["This week", "This month", "Last 3 months", "This year", "1–2 years", "Over 2 years", "Unknown"]

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// A span in days, as Workspace Watcher reports `activity_age`. Sub-day spans read
    /// in hours because "0d" since the last session is less useful than "4h".
    public static func dayCount(_ days: Double) -> String {
        if days < 1 { return "\(Int((days * 24).rounded()))h" }
        if days < 10 { return String(format: "%.1fd", days) }
        return "\(Int(days.rounded()))d"
    }
}
