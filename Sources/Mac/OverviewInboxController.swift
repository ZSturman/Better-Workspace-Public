import Foundation
import Observation
import AppKit
import CryptoKit
import BetterWorkspaceCore

/// One independent, shallow queue. Its actor never blocks app startup or the sidebar.
@MainActor @Observable
final class OverviewInboxController {
    typealias Review = WorkspaceInboxReview
    let workspace: URL
    private let stateDirectory: URL
    private var engine: Review.ReviewEngine?
    private var selected: Review.ReviewItem?
    private var widgetRequestedID: String?
    private var refreshedAt = Date.distantPast
    private(set) var item: OverviewInboxItem?
    private(set) var mobileItem: OverviewInboxItem?
    private(set) var reviewItems: [OverviewInboxItem] = []
    private(set) var checkedAt: Date?
    private(set) var busy = false
    private(set) var loading = false
    private(set) var verified = false
    private(set) var undoAvailable = false
    private(set) var document: Review.ContentDocument?
    private(set) var dueCount = 0
    private(set) var snoozedCount = 0
    var selectedIsFolder: Bool { selected?.kind == .folder }
    var message: String?
    /// The selected item on disk, for Quick Look and Reveal. Nil until verified.
    var selectedURL: URL? { verified ? selected?.url : nil }

    /// Rotation order, matching the engine's roots.
    static let folderNames = Review.ReviewConfiguration.folderNames + ["To Read"]

    init(workspace: URL) {
        self.workspace = workspace
        let token = SHA256.hash(data: Data(workspace.canonicalPath.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let support = TestIsolation.sandbox ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BetterWorkspace")
        stateDirectory = support.appendingPathComponent("OverviewReview/" + token)
    }

    private func readyEngine() async throws -> Review.ReviewEngine {
        if let engine { return engine }
        let directory = stateDirectory, root = workspace
        let created = try await Task.detached(priority: .utility) {
            var configuration = Review.ReviewConfiguration(workspace: root)
            // To Read joins when present; a missing root is skipped by the scan.
            configuration.roots.append(Review.Paths.physical(root).appendingPathComponent("To Read", isDirectory: true))
            return try Review.ReviewEngine(configuration: configuration, stateDirectory: directory)
        }.value
        try await created.recover()
        engine = created
        return created
    }

    func refresh(force: Bool = false, advance: Bool = false) async {
        guard !loading, !busy, force || Date().timeIntervalSince(refreshedAt) >= 30 else { return }
        loading = true
        defer { loading = false }
        let slow = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, self?.loading == true { self?.message = "Checking To folders in the background. You can keep using the app." }
        }
        defer { slow.cancel() }
        do {
            let engine = try await readyEngine()
            if force { await engine.invalidateCatalog() }
            let snapshot = await engine.snapshot()
            guard snapshot.catalog.warnings.isEmpty, snapshot.recoveryWarnings.isEmpty else {
                verified = false
                message = (snapshot.catalog.warnings + snapshot.recoveryWarnings).joined(separator: "\n")
                return
            }
            if advance { widgetRequestedID = nil }
            let requestedMissing = widgetRequestedID.map { id in !snapshot.catalog.items.contains(where: { $0.id == id }) } ?? false
            if requestedMissing {
                selected = nil; item = nil; document = nil; verified = false
            } else {
                let existing = advance ? nil : selected.flatMap { old in snapshot.catalog.items.first { $0.id == old.id } }
                if let existing { selected = existing } else { selected = try await engine.selectNext() }
            }
            if let selected {
                let content = try await engine.content(selected)
                document = content
                item = projection(selected, content: content, priority: snapshot.state.records[selected.id]?.priority)
            } else { item = nil; document = nil }
            snoozedCount = snapshot.catalog.items.filter {
                (snapshot.state.records[$0.id]?.snoozedUntil ?? .distantPast) > Date()
            }.count
            dueCount = snapshot.catalog.items.count - snoozedCount
            // A selected binary/folder is Mac-only. The phone can review another due
            // text/link item without forcing a download or reading an entire tree.
            let due = snapshot.catalog.items.filter {
                $0.kind == .file && $0.category != "To Organize" && $0.size <= 32_768
                    && (snapshot.state.records[$0.id]?.snoozedUntil ?? .distantPast) <= Date()
                    && (Review.ContentParser.textExtensions.contains($0.url.pathExtension.lowercased()) || ["webloc", "url"].contains($0.url.pathExtension.lowercased()))
            }
            let previousMobile = mobileItem
            if let selected, due.contains(where: { $0.id == selected.id }) { mobileItem = item }
            else if let next = due.min(by: { mobileOrder($0, snapshot) < mobileOrder($1, snapshot) }) {
                mobileItem = projection(next, content: try await engine.content(next), priority: snapshot.state.records[next.id]?.priority)
            } else { mobileItem = nil }
            let previousQueue = reviewItems
            var queue: [OverviewInboxItem] = []
            var ordered = due.sorted { mobileOrder($0, snapshot) < mobileOrder($1, snapshot) }
            if let id = mobileItem?.id, let index = ordered.firstIndex(where: { $0.id == id }) {
                let selected = ordered.remove(at: index); ordered.insert(selected, at: 0)
            }
            for candidate in ordered.prefix(8) {
                var value = projection(candidate, content: try await engine.content(candidate), priority: snapshot.state.records[candidate.id]?.priority)
                value.fingerprint = try await engine.fingerprint(candidate)
                queue.append(value)
            }
            if let selectedMobile = mobileItem, let index = queue.firstIndex(where: { $0.id == selectedMobile.id }) {
                let first = queue.remove(at: index); queue.insert(first, at: 0); mobileItem = first
            }
            reviewItems = queue
            undoAvailable = snapshot.undoAvailable
            // Only a changed answer is news to the phone; a fresh timestamp on every
            // check would republish the digest each sync for nothing.
            if checkedAt == nil || previousMobile != mobileItem || previousQueue != queue { checkedAt = Date() }
            refreshedAt = Date(); verified = !requestedMissing
            message = requestedMissing ? "This review item is no longer available. Choose Next to continue reviewing." : nil
        } catch is CancellationError {
            // A newer refresh replaced this one; it has nothing to report.
        } catch { verified = false; message = error.localizedDescription }
    }

    /// Least recently shown first; ties go to the folder whose turn is next, so the
    /// phone rotates through To folders the same way the Mac does.
    private func mobileOrder(_ item: Review.ReviewItem, _ snapshot: Review.EngineSnapshot) -> (Int, Date, Int, String) {
        let roots = Self.folderNames
        let index = roots.firstIndex(of: item.category) ?? roots.count
        let turn = (index - snapshot.state.nextRoot % roots.count + roots.count) % roots.count
        return (-(snapshot.state.records[item.id]?.priority ?? 3), snapshot.state.records[item.id]?.lastShown ?? .distantPast, turn, item.url.path)
    }

    private func projection(_ selected: Review.ReviewItem, content: Review.ContentDocument, priority: Int? = nil) -> OverviewInboxItem {
        let path = String(selected.url.canonicalPath.dropFirst(workspace.canonicalPath.count + 1))
        return OverviewInboxItem(id: selected.id, path: path, title: selected.name, category: selected.category,
            modified: selected.modified, size: selected.size, preview: String(content.body.prefix(4_000)), link: content.links.first, priority: priority)
    }

    /// Read-only, shallow folder preview; decisions still apply to the whole item.
    func previewChildren() async throws -> [Review.ReviewItem] {
        guard verified, let selected, selected.kind == .folder else { return [] }
        return try await readyEngine().children(selected)
    }

    func selectWidgetItem(id: String) async {
        widgetRequestedID = id
        let engine = try? await readyEngine()
        if let snapshot = await engine?.snapshot(), let candidate = snapshot.catalog.items.first(where: { $0.id == id }) {
            selected = candidate
        }
        await refresh(force: true)
    }

    func open() {
        guard verified, let selected else { return }
        NSWorkspace.shared.open(item?.link ?? selected.url)
    }

    func act(_ outcome: Review.Outcome, destination: URL? = nil) async {
        guard verified, let selected, !busy else { return }
        busy = true
        do {
            let engine = try await readyEngine()
            let fingerprint = try await engine.fingerprint(selected)
            _ = try await engine.perform(selected, outcome: outcome, expectedFingerprint: fingerprint, destinationDirectory: destination,
                trash: { url in
                    if let isolated = TestIsolation.trashDirectory {
                        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
                        let to = Review.Filesystem.uniqueDestination(isolated.appendingPathComponent(url.lastPathComponent))
                        try Review.Filesystem.move(url, to: to); return to
                    }
                    var result: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                    guard let result else { throw Review.ReviewError.message("Trash did not return a recoverable location.") }
                    return result as URL
                })
            self.selected = nil; item = nil
        } catch { message = error.localizedDescription }
        busy = false
        if self.selected == nil { await refresh(force: true, advance: true) }
    }

    func setPriority(_ priority: Int) async {
        guard verified, let selected, !busy else { return }
        do {
            let engine = try await readyEngine()
            try await engine.setPriority(priority, for: selected)
            await refresh(force: true)
        } catch { message = error.localizedDescription }
    }

    func snooze(days: Int) async {
        guard verified, let selected, !busy else { return }
        do {
            let engine = try await readyEngine()
            let until = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date()))!
            try await engine.snooze(selected, until: until)
            self.selected = nil
            await refresh(force: true, advance: true)
        } catch { message = error.localizedDescription }
    }

    func undo() async {
        guard !busy else { return }
        busy = true
        do { _ = try await readyEngine().undo(); selected = nil }
        catch { message = error.localizedDescription }
        busy = false
        await refresh(force: true)
    }

    /// Only an explicit phone decision reaches this path. A retry uses the command's
    /// stable ID in the operation journal, including a crash before the CloudKit receipt.
    func apply(_ command: OverviewInboxCommand, operationID: UUID) async throws {
        // A Mac action in flight finishes in seconds; a refusal here would become a
        // permanent error receipt on the phone for what is only a moment's overlap.
        let deadline = Date().addingTimeInterval(30)
        while busy || loading, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard !busy else { throw Review.ReviewError.message("Another inbox action is still running on the Mac. Save this decision again later.") }
        busy = true
        defer { busy = false }
        let engine = try await readyEngine()
        if await engine.history().contains(where: { $0.id == operationID && $0.status == "committed" }) { return }
        let url = try MobilePlanningFiles.resolve(command.item.path, workspace: WorkspaceLocation(root: workspace))
        guard command.item.category != "To Organize", command.item.path.split(separator: "/").count == 2,
              command.item.path.split(separator: "/").first.map(String.init) == command.item.category,
              Review.ReviewConfiguration.folderNames.contains(command.item.category) || command.item.category == "To Read" else {
            throw Review.ReviewError.message("This review requires the Mac.")
        }
        let root = workspace.appendingPathComponent(command.item.category)
        let current: Review.ReviewItem
        do { current = try await Task.detached(priority: .utility) { try Review.Filesystem.info(url, root: root) }.value }
        catch { throw Review.ReviewError.message("“\(command.item.title)” is no longer in \(command.item.category). It may already have been reviewed on the Mac.") }
        guard current.kind == .file, current.id == command.item.id, current.modified == command.item.modified, current.size == command.item.size else {
            throw Review.ReviewError.message("“\(command.item.title)” changed on the Mac after your phone saw it. Nothing was moved; review its current version.")
        }
        let freshFingerprint = try await engine.fingerprint(current)
        if let expected = command.item.fingerprint, freshFingerprint != expected {
            throw Review.ReviewError.message("The contents changed since the widget preview. Nothing was moved; refresh and review again.")
        }
        if command.action == .prioritize, let priority = command.priority {
            try await engine.setPriority(priority, for: current)
        } else if command.action == .snooze, let until = command.until {
            try await engine.snooze(current, until: until)
        } else {
            let outcome: Review.Outcome = command.action == .done ? .done : command.action == .archive ? .archive : .retire
            _ = try await engine.perform(current, outcome: outcome, expectedFingerprint: command.item.fingerprint ?? freshFingerprint, operationID: operationID)
        }
        if selected?.id == current.id { selected = nil; item = nil }
        if widgetRequestedID == current.id { widgetRequestedID = nil }
        mobileItem = nil
        await engine.invalidateCatalog()
        refreshedAt = .distantPast
    }
}
