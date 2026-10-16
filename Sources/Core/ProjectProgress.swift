import Foundation

/// The numbers behind a project's progress charts, computed from its work records'
/// own dates. Nothing here is stored; it is recomputed from the files.
public struct ProjectProgress: Sendable, Equatable {

    public struct Week: Sendable, Equatable, Identifiable {
        public let start: Date
        /// Open at the end of the week (created by then, not completed by then).
        public let open: Int
        /// Completed during the week.
        public let completed: Int
        /// Created during the week.
        public let created: Int
        public var id: Date { start }
    }

    public struct Forecast: Sendable, Equatable {
        /// Completions per week over the recent window.
        public let weeklyRate: Double
        /// When the open items would be done at that rate.
        public let finish: Date
        public let remaining: Int
    }

    public let weeks: [Week]
    public let forecast: Forecast?
    public let open: Int
    public let completed: Int

    /// Weekly history over the last `weeks` weeks, and a straight-line forecast from the
    /// completion rate of the last `rateWindow` weeks. No forecast without recent
    /// completions: a rate of zero predicts nothing honest.
    public static func make(_ items: [WorkItem], now: Date = Date(), weeks count: Int = 12,
                            rateWindow: Int = 6, calendar: Calendar = .current) -> ProjectProgress {
        var calendar = calendar
        calendar.firstWeekday = 2
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let starts = (0..<count).reversed().compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }

        func done(_ item: WorkItem) -> Date? {
            item.status == .completed ? (item.completedAt ?? item.modifiedAt) : nil
        }
        let weeks = starts.map { start -> Week in
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? start
            var open = 0, completed = 0, created = 0
            for item in items {
                let born = item.createdAt ?? .distantPast
                let finished = done(item)
                if born < end, (finished.map { $0 >= end } ?? true) { open += 1 }
                if let finished, finished >= start, finished < end { completed += 1 }
                if let made = item.createdAt, made >= start, made < end { created += 1 }
            }
            return Week(start: start, open: open, completed: completed, created: created)
        }

        let openNow = items.filter { $0.status != .completed }.count
        let recent = weeks.suffix(rateWindow)
        let rate = recent.isEmpty ? 0 : Double(recent.map(\.completed).reduce(0, +)) / Double(recent.count)
        var forecast: Forecast?
        if rate > 0, openNow > 0 {
            let weeksLeft = Double(openNow) / rate
            if let finish = calendar.date(byAdding: .day, value: Int((weeksLeft * 7).rounded(.up)), to: now) {
                forecast = Forecast(weeklyRate: rate, finish: finish, remaining: openNow)
            }
        }
        return ProjectProgress(weeks: weeks, forecast: forecast, open: openNow,
                               completed: items.count - openNow)
    }
}
