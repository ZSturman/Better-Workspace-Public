import XCTest
@testable import BetterWorkspaceCore

/// Capability-aware layouts: a view is offered because the contents support it, and
/// when it isn't, the reason is specific enough to act on.
final class AreaCapabilitiesTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int = 15) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func item(_ name: String, created: Date? = nil, changed: Date? = nil,
                      directory: Bool = false, children: Int? = nil) -> WorkspaceItem {
        let url = URL(fileURLWithPath: "/tmp/Area/\(name)")
        return WorkspaceItem(url: url, name: name, isDirectory: directory,
                             kind: FileKind.classify(url: url, isDirectory: directory),
                             identity: nil, byteSize: 10, createdAt: created, rawModifiedAt: changed,
                             contentModifiedAt: changed, immediateChildCount: directory ? (children ?? 0) : nil)
    }

    // MARK: Dates in names

    func testNameDatesAreReadFromTheFormsTheWorkspaceActuallyUses() {
        let now = date(2026, 9, 30)
        func day(_ name: String) -> DateComponents? {
            ItemDates.nameDate(in: name, now: now, calendar: calendar)
                .map { calendar.dateComponents([.year, .month, .day], from: $0) }
        }
        XCTAssertEqual(day("Screenshot 2026-04-14 at 10.06.52 PM.png"), DateComponents(year: 2026, month: 4, day: 14))
        XCTAssertEqual(day("20260720-statements-0373-.pdf"), DateComponents(year: 2026, month: 7, day: 20))
        XCTAssertEqual(day("telemetry-consolidation-20260917-214818"), DateComponents(year: 2026, month: 9, day: 17))
        // A range reads as of its end.
        XCTAssertEqual(day("AggregateAnalytics_Z_2025-08-06_2026-08-05.xlsx"), DateComponents(year: 2026, month: 8, day: 5))
    }

    func testThingsThatOnlyLookLikeDatesAreNotBelieved() {
        let now = date(2026, 9, 30)
        for name in ["IMG_0446.HEIC", "Abstractbutrecognizableapp_14255530.png", "2026-02-31 notes.md",
                     "2027-01-01 plan.md", "120260101.txt", "Fixture 2026-1-5.md"] {
            XCTAssertNil(ItemDates.nameDate(in: name, now: now, calendar: calendar), name)
        }
    }

    func testAddedPrefersTheNameAndSaysSo() {
        let copied = item("Screenshot 2025-09-02 at 14.35.34.png", created: date(2026, 9, 1))
        XCTAssertEqual(ItemDates.date(of: copied, basis: .added)?.source, .name)
        let plain = item("Walking.jpg", created: date(2020, 1, 3))
        XCTAssertEqual(ItemDates.date(of: plain, basis: .added), ItemDate(date: date(2020, 1, 3), source: .created))
        XCTAssertEqual(ItemDates.date(of: copied, basis: .changed), nil, "No content date was given")
    }

    // MARK: Timeline

    func testATimelineNeedsDatesThatSpreadOut() {
        // Ideas today: every item created the same month.
        let sameMonth = (1...5).map { item("Idea \($0)", created: date(2026, 9, $0), directory: true) }
        let ideas = AreaCapabilities(items: sameMonth, calendar: calendar)
        XCTAssertFalse(ideas.hasTimeline)
        XCTAssertEqual(ideas.availability(of: .timeline, purposeBuilt: nil).reason,
                       "Everything here dates from September 2026")

        // Ideas as it really is: one straggler does not make a history.
        let straggler = AreaCapabilities(items: sameMonth + [item("Old", created: date(2026, 5))], calendar: calendar)
        XCTAssertFalse(straggler.hasTimeline)
        XCTAssertEqual(straggler.availability(of: .timeline, purposeBuilt: nil).reason,
                       "5 of 6 items date from September 2026")

        // To Organize today: years of arrivals.
        let spread = [item("a.pdf", created: date(2022, 12)), item("b.png", created: date(2024, 6)),
                      item("c.xlsx", created: date(2026, 8)), item("d.zip", created: date(2026, 9))]
        let organize = AreaCapabilities(items: spread, calendar: calendar)
        XCTAssertTrue(organize.hasTimeline)
        XCTAssertEqual(organize.availability(of: .timeline, purposeBuilt: nil), .available)
        XCTAssertEqual(organize.monthCount[.added], 4)
    }

    func testTheBasisThatSpreadsFurtherIsPreferred() {
        // Projects today: reorganisation reset creation months; content changes kept theirs.
        let projects = (1...6).map { item("P\($0)", created: date(2026, 9), changed: date(2025, $0 + 3), directory: true, children: 2) }
        let capabilities = AreaCapabilities(items: projects, calendar: calendar)
        XCTAssertFalse(capabilities.hasTimeline(.added))
        XCTAssertTrue(capabilities.hasTimeline(.changed))
        XCTAssertEqual(capabilities.preferredDateBasis, .changed)
    }

    // MARK: Gallery, outline, queue

    func testGalleryNeedsEnoughPictures() {
        let docs = (1...10).map { item("doc\($0).pdf") }
        XCTAssertFalse(AreaCapabilities(items: docs).hasVisualMedia)
        XCTAssertEqual(AreaCapabilities(items: docs + [item("one.png")]).availability(of: .gallery, purposeBuilt: nil).reason,
                       "Only 1 of 11 items are images or video")
        XCTAssertTrue(AreaCapabilities(items: docs + [item("a.png"), item("b.jpg"), item("c.mp4")]).hasVisualMedia)
        XCTAssertTrue(AreaCapabilities(items: [item("only.png"), item("notes.md")]).hasVisualMedia)
    }

    func testAnOutlineNeedsSomethingToOpen() {
        XCTAssertFalse(AreaCapabilities(items: [item("Empty", directory: true, children: 0), item("a.md")]).hasHierarchy)
        XCTAssertTrue(AreaCapabilities(items: [item("Animation", directory: true, children: 4)]).hasHierarchy)
    }

    func testAWorkQueueIsForWorkNotForFolderOfFiles() {
        let files = AreaCapabilities(items: [item("a.png"), item("b.pdf")])
        XCTAssertFalse(files.availability(of: .workQueue, purposeBuilt: nil).isAvailable)
        XCTAssertTrue(files.availability(of: .workQueue, purposeBuilt: nil, isWorkQueue: true).isAvailable)
        XCTAssertTrue(AreaCapabilities(items: []).availability(of: .workQueue, purposeBuilt: nil).isAvailable,
                      "An empty folder is a fine place to start a queue")
        XCTAssertTrue(AreaCapabilities(items: [item("x.bw.md")], workItemCount: 1)
            .availability(of: .workQueue, purposeBuilt: nil).isAvailable)
    }

    func testListAndTableAlwaysApplyAndAMissingViewFallsBackToTheList() {
        let empty = AreaCapabilities(items: [])
        for layout in [AreaLayout.list, .table] {
            XCTAssertTrue(empty.availability(of: layout, purposeBuilt: nil).isAvailable)
        }
        XCTAssertEqual(empty.resolve(.timeline, purposeBuilt: nil), .list)
        XCTAssertEqual(empty.resolve(.gallery, purposeBuilt: nil), .list)
        XCTAssertEqual(empty.resolve(.purposeBuilt, purposeBuilt: .projects), .purposeBuilt)
    }

    // MARK: Configuration

    func testDateBasisLayersAndOldSettingsFilesStillDecode() throws {
        let personal = AreaConfiguration(dateBasis: .changed)
        XCTAssertEqual(personal.layered(over: AreaConfiguration(layout: .timeline)).dateBasis, .changed)
        XCTAssertNil(AreaSettings(resolving: AreaConfiguration(layout: .timeline), purposeBuilt: nil).dateBasis,
                     "No basis chosen means the contents decide")

        // Written before timelines existed.
        let old = #"{"layout":"table","sort":"newest"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AreaConfiguration.self, from: old)
        XCTAssertEqual(decoded.layout, .table)
        XCTAssertNil(decoded.dateBasis)
    }

    func testAQueueConfiguredByKindIsAQueueEvenWhileListed() {
        let settings = AreaSettings(resolving: AreaDefaults.configuration(forFolderNamed: "To Do")
            .layered(over: AreaConfiguration()), purposeBuilt: nil)
        XCTAssertTrue(settings.isWorkQueue)
        let listed = AreaSettings(resolving: AreaConfiguration(layout: .list), purposeBuilt: nil)
        XCTAssertFalse(listed.isWorkQueue)
    }
}

/// A filesystem change invalidates only what it could have made stale.
final class CacheInvalidationTests: XCTestCase {
    func testAChangeInvalidatesItselfAndItsAncestorsOnly() {
        let changed = ["/tmp/W/Projects/Alpha/src/main.swift"]
        XCTAssertTrue(CacheInvalidation.isAffected("/tmp/W/Projects/Alpha", by: changed))
        XCTAssertTrue(CacheInvalidation.isAffected("/tmp/W/Projects", by: changed))
        XCTAssertTrue(CacheInvalidation.isAffected("/tmp/W/Projects/Alpha/src/main.swift", by: changed))
        XCTAssertFalse(CacheInvalidation.isAffected("/tmp/W/Projects/Beta", by: changed))
        XCTAssertFalse(CacheInvalidation.isAffected("/tmp/W/Projects/Al", by: changed),
                       "A name that merely starts the same is a sibling, not an ancestor")
        XCTAssertFalse(CacheInvalidation.isAffected("/tmp/W/Projects/Alpha/docs", by: changed))
    }
}
