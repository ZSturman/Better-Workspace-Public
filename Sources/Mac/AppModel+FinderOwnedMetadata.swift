import Foundation
import BetterWorkspaceCore

/// Finder Workspace Extensions owns project status, phase, domain, portfolio priority,
/// maintenance cadence, completion model and status details (`docs/PROJECT_EXCHANGE.md`).
/// This mirror applies the values it publishes in the `finder-workspace` exchange folder,
/// including over a value a Notion pull just brought in, and queues them for Notion, which
/// stays a backup. Edits made in this app are sent there as base-checked requests.
@MainActor
final class FinderOwnedMetadataMirror {
    let files = ExchangeFiles.standard(source: FinderOwnedMetadata.sourceID)
    private(set) var snapshot: ExchangeSnapshot?
    private var snapshotModified: Date?
    /// Rows from receipts newer than the snapshot, by project id.
    private var receiptRows: [String: (row: ExchangeProject, at: Date)] = [:]
    /// Edits sent from this app and not yet answered, by request id. Memory only: after a
    /// relaunch the owner's next publication shows each outcome.
    private var waiting: [UUID: (projectID: String, changes: [ExchangeChange])] = [:]
    private(set) var lastError: String?
    var active = false
    /// The Notion graph revision last compared with the owned values.
    private var comparedGraphRevision: Int?

    /// The owner's current row for a project, when it lists one.
    func row(_ projectID: String) -> ExchangeProject? {
        receiptRows[projectID]?.row ?? snapshot?.projects.first { $0.id == projectID }
    }

    private func waitingFields(_ projectID: String) -> Set<ExchangeField> {
        Set(waiting.values.filter { $0.projectID == projectID }.flatMap { $0.changes.map(\.field) })
    }

    func pass(model: AppModel) {
        guard active else { return }
        readSnapshotIfChanged()
        collectReceipts(model: model)
        // A stopped or removed owner leaves values as they are until it publishes again.
        guard let snapshot, snapshot.isCurrent(), model.exchangeListingComplete else { return }
        var changed: [String: Set<ExchangeField>] = [:]
        let stored = model.projectStore.allMetadata()
        for projectID in Set(snapshot.projects.map(\.id)).union(receiptRows.keys) {
            guard let row = row(projectID) else { continue }
            let result = FinderOwnedMetadata.mirror(row, onto: stored[projectID] ?? ProjectMetadata(), skipping: waitingFields(projectID))
            guard !result.changed.isEmpty, model.projectStore.record(id: projectID) != nil else { continue }
            do { try model.projectStore.saveMetadata(result.metadata, for: projectID); changed[projectID] = result.changed }
            catch { lastError = "Couldn’t mirror Finder Workspace values: \(error.localizedDescription)" }
        }
        if !changed.isEmpty { model.refreshOverview(); model.requestMobileCloudSync() }
        if !changed.isEmpty || comparedGraphRevision != model.graphRevision {
            queueNotionDifferences(owned: Set(snapshot.projects.map(\.id)), model: model)
        }
    }

    /// Queues owned values that differ from a linked Notion page's draft, so Notion keeps a
    /// copy. Compares rather than queueing each change once: the Notion records load after
    /// launch, and a value mirrored before then must still be sent. Projects without a
    /// Notion page get no new-page draft; creating pages stays a reviewed action.
    private func queueNotionDifferences(owned: Set<String>, model: AppModel) {
        guard let source = model.graphSources.first(where: { $0.kind == .projects }) else { return }
        comparedGraphRevision = model.graphRevision
        let stored = model.projectStore.allMetadata()
        for item in model.projects() {
            guard let id = model.projectRecord(for: item)?.id, owned.contains(id),
                  let graph = model.graphProject(for: item), graph.pageID != nil else { continue }
            let metadata = stored[id] ?? ProjectMetadata(), waiting = waitingFields(id)
            let names = Set(FinderOwnedMetadata.fields.compactMap { field -> String? in
                guard !waiting.contains(field), let name = ProjectExchangeMetadata.notionNames[field],
                      source.property(named: name) != nil else { return nil }
                let owned = ExchangeText.clean(ProjectExchangeMetadata.value(field, in: metadata))
                return ExchangeText.clean(graph.value(name, source: source).display) == owned ? nil : name
            })
            if !names.isEmpty { model.queueProjectGraphEdits(for: item, fields: names) }
        }
    }

    /// Sends this app's edit of shared fields to the owner. Without a listing for the
    /// project (not linked there yet), the value stays here and the owner adopts it when
    /// it links the folder.
    func submit(projectID: String, path: String, from old: ProjectMetadata, to new: ProjectMetadata,
                only fields: Set<ExchangeField>? = nil, model: AppModel) {
        guard active, row(projectID) != nil,
              let request = FinderOwnedMetadata.request(projectID: projectID, projectPath: path, from: old, to: new, only: fields) else { return }
        do {
            try files.submit(request)
            waiting[request.id] = (projectID, request.changes)
            DistributedNotificationCenter.default().postNotificationName(.init(ExchangeFiles.requestNotification), object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
        } catch {
            lastError = "Couldn’t send this change to Finder Workspace: \(error.localizedDescription)"
            model.statusMessage = lastError
        }
    }

    private func readSnapshotIfChanged() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: files.snapshotURL.path))?[.modificationDate] as? Date
        guard let modified, modified != snapshotModified else { return }
        do {
            let next = try files.readSnapshot()
            guard next.sourceID == FinderOwnedMetadata.sourceID else { return }
            snapshot = next; snapshotModified = modified; lastError = nil
            receiptRows = receiptRows.filter { $0.value.at > next.generatedAt }
        } catch { lastError = "Couldn’t read Finder Workspace’s project values: \(error.localizedDescription)" }
    }

    private func collectReceipts(model: AppModel) {
        for id in Array(waiting.keys) {
            // The receipt is written before the claim is released, so check it again after.
            if let receipt = files.receipt(id) ?? (files.isPending(id) ? nil : files.receipt(id)) {
                waiting[id] = nil; files.removeReceipt(id)
                if let row = receipt.project, receipt.processedAt > (snapshot?.generatedAt ?? .distantPast) { receiptRows[row.id] = (row, receipt.processedAt) }
                if receipt.outcome == .conflict || receipt.outcome == .rejected {
                    model.statusMessage = "Finder Workspace kept its value. \(receipt.message)"
                }
            } else if !files.isPending(id) {
                // Withdrawn or lost: the owner's published value applies again.
                waiting[id] = nil
            }
        }
    }
}

extension AppModel {
    var finderOwnedMetadata: FinderOwnedMetadataMirror { ProjectExchangeHost.shared.ownedMetadata }

    /// Sends a shared-field edit made in this app (editor Save, reviewed import, a Notion
    /// draft edited here) to Finder Workspace, which owns those values.
    func forwardOwnedMetadata(projectID: String, from old: ProjectMetadata, to new: ProjectMetadata, only fields: Set<ExchangeField>? = nil) {
        guard let record = projectStore.record(id: projectID) else { return }
        finderOwnedMetadata.submit(projectID: projectID, path: URL(fileURLWithPath: record.lastPath).canonicalPath,
                                   from: old, to: new, only: fields, model: self)
    }
}
