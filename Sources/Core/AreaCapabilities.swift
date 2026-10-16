import Foundation

// MARK: - Dates

/// Which date a timeline lays an area out by.
public enum AreaDateBasis: String, CaseIterable, Codable, Sendable, Identifiable {
    /// When the item came to exist: a date in its name if it carries one (screenshots,
    /// statements, exports), otherwise its creation date.
    case added
    /// When its content last changed. For a folder, the newest immediate child — see
    /// `WorkspaceItem.contentModifiedAt`.
    case changed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .added: return "Added"
        case .changed: return "Changed"
        }
    }
}

/// A date for one item, and where it came from.
///
/// The source is kept because the three are not equally trustworthy: a date in the
/// name is what the file says about itself, a creation date is what the disk says, and
/// a copy or reorganisation resets both of the latter. A timeline shows which it used.
public struct ItemDate: Hashable, Sendable {
    public enum Source: String, Sendable {
        case name, created, modified
    }

    public let date: Date
    public let source: Source

    public init(date: Date, source: Source) {
        self.date = date
        self.source = source
    }
}

public enum ItemDates {

    public static func date(of item: WorkspaceItem, basis: AreaDateBasis) -> ItemDate? {
        switch basis {
        case .added:
            if let named = nameDate(in: item.name) { return ItemDate(date: named, source: .name) }
            return item.createdAt.map { ItemDate(date: $0, source: .created) }
        case .changed:
            return item.contentModifiedAt.map { ItemDate(date: $0, source: .modified) }
        }
    }

    // `2026-04-14`, `2026_04_14`, `20260720`. Not preceded or followed by another digit,
    // so `IMG_0446` and 8-digit asset ids that happen to start `20…` mostly stay out;
    // the calendar check below rejects the rest.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![0-9])((?:19|20)[0-9]{2})([-_.]?)(0[1-9]|1[0-2])\2(0[1-9]|[12][0-9]|3[01])(?![0-9])"#
    )

    /// The date a file name states, if it states one.
    ///
    /// The last date wins: `…_2025-08-06_2026-08-05.xlsx` is a report *as of* its end
    /// date. Dates before 1990 or after `now` are not believed.
    public static func nameDate(in name: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let range = NSRange(name.startIndex..., in: name)
        for match in pattern.matches(in: name, range: range).reversed() {
            guard let year = Int(substring(name, match.range(at: 1))),
                  let month = Int(substring(name, match.range(at: 3))),
                  let day = Int(substring(name, match.range(at: 4)))
            else { continue }
            let components = DateComponents(year: year, month: month, day: day, hour: 12)
            // `DateComponents` happily rolls 31 February into March; reject it instead.
            guard components.isValidDate(in: calendar), let date = calendar.date(from: components),
                  year >= 1990, date <= now.addingTimeInterval(86_400)
            else { continue }
            return date
        }
        return nil
    }

    private static func substring(_ string: String, _ range: NSRange) -> String {
        Range(range, in: string).map { String(string[$0]) } ?? ""
    }
}

// MARK: - Capabilities

/// Whether a layout makes sense for an area right now, and if not, why not.
public enum AreaLayoutAvailability: Hashable, Sendable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }

    public var reason: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

/// What an area's current contents can support, measured from the items themselves.
///
/// This is what makes layouts capability-aware: a timeline is offered because items
/// span more than one month, not because a folder is called "Calendar". Measured on the
/// immediate children the app already holds, so it costs nothing extra to compute and
/// changes the moment the folder's contents do.
public struct AreaCapabilities: Sendable {
    public let itemCount: Int
    public let visualMediaCount: Int
    /// Immediate subfolders that hold something. Only these are worth expanding.
    public let expandableFolderCount: Int
    /// Better Workspace work items anywhere below the folder.
    public let workItemCount: Int
    /// Items with a date, and the distinct calendar months they fall in, per basis.
    public let datedCount: [AreaDateBasis: Int]
    public let monthCount: [AreaDateBasis: Int]
    /// The month holding the most dated items, and how many it holds.
    public let busiestMonth: [AreaDateBasis: (start: Date, count: Int)]

    /// Beyond this share in one month, a time axis is one bar and a few stragglers.
    public static let maximumSingleMonthShare = 0.8

    public init(items: [WorkspaceItem], workItemCount: Int = 0, calendar: Calendar = .current) {
        itemCount = items.count
        visualMediaCount = items.filter { $0.kind.isVisualMedia }.count
        expandableFolderCount = items.filter { $0.isDirectory && ($0.immediateChildCount ?? 0) > 0 }.count
        self.workItemCount = workItemCount
        var dated: [AreaDateBasis: Int] = [:]
        var months: [AreaDateBasis: Int] = [:]
        var busiest: [AreaDateBasis: (start: Date, count: Int)] = [:]
        for basis in AreaDateBasis.allCases {
            let starts = items.compactMap { ItemDates.date(of: $0, basis: basis) }
                .compactMap { calendar.dateInterval(of: .month, for: $0.date)?.start }
            dated[basis] = starts.count
            let perMonth = Dictionary(grouping: starts, by: { $0 }).mapValues(\.count)
            months[basis] = perMonth.count
            if let top = perMonth.max(by: { $0.value < $1.value }) { busiest[basis] = (top.key, top.value) }
        }
        datedCount = dated
        monthCount = months
        busiestMonth = busiest
    }

    // MARK: Individual capabilities

    /// Enough pictures that thumbnails are the fastest way to recognise things: three
    /// or more, or at least half the folder.
    public var hasVisualMedia: Bool {
        visualMediaCount >= 3 || (visualMediaCount >= 1 && visualMediaCount * 2 >= itemCount)
    }

    /// A time axis says something only when the dates actually spread out: at least
    /// three dated items, over more than one month, without one month holding nearly
    /// all of them. Ideas on 2026-09-30 is the case this rules out — 30 of 31 created in
    /// the same month, and one straggler, is not a history.
    public func hasTimeline(_ basis: AreaDateBasis) -> Bool {
        let dated = datedCount[basis] ?? 0
        guard dated >= 3, (monthCount[basis] ?? 0) >= 2 else { return false }
        return Double(busiestMonth[basis]?.count ?? dated) / Double(dated) <= Self.maximumSingleMonthShare
    }

    public var hasTimeline: Bool { AreaDateBasis.allCases.contains(where: hasTimeline) }

    public var hasHierarchy: Bool { expandableFolderCount > 0 }

    /// For an area that has not chosen: when things arrived, if that spreads out at all —
    /// it is the steadier meaning, and it does not reshuffle every time a file is edited.
    /// Otherwise when they changed, which is what survives a reorganisation that reset
    /// every creation date (Projects, 2026-09).
    public var preferredDateBasis: AreaDateBasis {
        hasTimeline(.added) || hasTimeline(.changed) == false ? .added : .changed
    }

    // MARK: Layouts

    /// Whether `layout` is a meaningful way to look at this area.
    ///
    /// List and table always are: they work for anything. The rest each depend on one
    /// property of the contents, and say which one when it is missing, so the choice
    /// teaches what would make it appear rather than silently hiding it.
    ///
    /// - Parameter isWorkQueue: the area is set up for work items (a work-item kind is
    ///   configured), so a queue is its intended use even while it is empty.
    public func availability(of layout: AreaLayout, purposeBuilt: WorkspaceArea?,
                             isWorkQueue: Bool = false) -> AreaLayoutAvailability {
        switch layout {
        case .list, .table:
            return .available
        case .purposeBuilt:
            return purposeBuilt == nil ? .unavailable(reason: "No dedicated view exists for this folder") : .available
        case .gallery:
            if hasVisualMedia { return .available }
            if itemCount == 0 { return .unavailable(reason: "Needs images or video; the folder is empty") }
            if visualMediaCount == 0 { return .unavailable(reason: "Needs images or video; none here") }
            return .unavailable(reason: "Only \(visualMediaCount) of \(itemCount) items are images or video")
        case .timeline:
            if hasTimeline { return .available }
            let basis = AreaDateBasis.allCases.max { (datedCount[$0] ?? 0) < (datedCount[$1] ?? 0) } ?? .added
            if (datedCount[basis] ?? 0) < 3 {
                return .unavailable(reason: itemCount == 0 ? "Needs dated items; the folder is empty"
                                                           : "Needs at least three dated items")
            }
            if let busiest = busiestMonth[basis] {
                let month = Self.monthFormatter.string(from: busiest.start)
                let dated = datedCount[basis] ?? 0
                return .unavailable(reason: busiest.count == dated
                    ? "Everything here dates from \(month)"
                    : "\(busiest.count) of \(dated) items date from \(month)")
            }
            return .unavailable(reason: "Needs items from more than one month")
        case .outline:
            return hasHierarchy ? .available : .unavailable(reason: "Needs subfolders with something in them")
        case .workQueue:
            // A queue writes its own contents, so an empty folder is a fine place to
            // start one. A folder of ordinary files is not a queue by any measure.
            if isWorkQueue || workItemCount > 0 || itemCount == 0 { return .available }
            return .unavailable(reason: "Holds files, not Better Workspace work items")
        }
    }

    /// The layout to actually draw: the chosen one if it still applies, otherwise the
    /// list, which always does. A folder that empties never shows a broken view.
    public func resolve(_ layout: AreaLayout, purposeBuilt: WorkspaceArea?, isWorkQueue: Bool = false) -> AreaLayout {
        availability(of: layout, purposeBuilt: purposeBuilt, isWorkQueue: isWorkQueue).isAvailable ? layout : .list
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()
}
