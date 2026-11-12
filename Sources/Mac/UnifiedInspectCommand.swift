import Foundation
import BetterWorkspaceCore

/// `BetterWorkspace --unified inspect [<record-id> …] [--title <text>]`
///
/// Read-only diagnostics for the unified workspace journal, which lives in the app's
/// group container and cannot be read from a shell. Prints JSON: record counts, and for
/// each named record (or each whose title contains the text) its heads and full revision
/// history. Loads under the store's own lock and exits before any window exists; never
/// writes, syncs or touches the Workspace.
enum UnifiedInspectCommand {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--unified") else { return }
        if args.indices.contains(index + 1), args[index + 1] == "peers" { comparePeers() }
        do {
            guard args.indices.contains(index + 1), args[index + 1] == "inspect" else {
                throw WorkspaceReplicaError.invalid("Use --unified inspect [<record-id> …] [--title <text>] or --unified peers")
            }
            let rest = Array(args[(index + 2)...])
            let title = rest.firstIndex(of: "--title").flatMap { rest.indices.contains($0 + 1) ? rest[$0 + 1] : nil }
            let ids = Set(rest.compactMap(UUID.init(uuidString:)))
            let directory = WorkspaceSession.storageDirectory
            let settings = try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("settings.json"))) as? [String: Any]
            let replica = try WorkspaceReplicaStore(directory: directory, initialWorkspaceID: UUID()).load()
            let history = Dictionary(grouping: replica.revisions, by: \.recordID)
            let titles = replica.displayTitles
            let date = ISO8601DateFormatter()
            func describe(_ revision: WorkspaceRecordRevision) -> [String: Any] {
                ["id": revision.id.uuidString, "parents": revision.parents.map(\.uuidString).sorted(), "device": revision.deviceID.uuidString,
                 "origin": "\(revision.origin)", "createdAt": date.string(from: revision.createdAt), "kind": "\(revision.content.kind)",
                 "title": revision.content.title, "deleted": revision.content.isDeleted, "complete": revision.content.isComplete,
                 "parent": revision.content.parentID?.uuidString ?? NSNull()]
            }
            let selected = replica.records.filter { state in
                ids.contains(state.id) || title.map { text in (history[state.id] ?? []).contains { $0.content.title.localizedCaseInsensitiveContains(text) } } == true
            }
            let records: [[String: Any]] = selected.map { state in
                ["id": state.id.uuidString, "displayTitle": titles[state.id] ?? NSNull(), "conflict": state.isConflict,
                 "heads": state.heads.map(describe),
                 "history": (history[state.id] ?? []).sorted { $0.createdAt < $1.createdAt }.map(describe)]
            }
            let live = replica.records.filter { $0.resolved.map { !$0.content.isDeleted } ?? false }
            let output: [String: Any] = [
                "deviceID": settings?["deviceID"] ?? NSNull(), "workspaceID": replica.workspaceID.uuidString,
                "records": replica.records.count, "revisions": replica.revisions.count,
                "live": live.count, "deleted": replica.records.filter { $0.resolved?.content.isDeleted == true }.count,
                "conflicts": replica.records.filter(\.isConflict).count,
                "liveByKind": Dictionary(grouping: live, by: { "\($0.resolved!.content.kind)" }).mapValues(\.count),
                "matches": records,
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            exit(0)
        } catch {
            fputs("Unified inspect: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// `BetterWorkspace --unified peers`: what each device last published to iCloud, against
    /// this Mac's journal. Read-only: one zone fetch, no upload, no local write.
    private static func comparePeers() {
        let semaphore = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let directory = WorkspaceSession.storageDirectory
                let settings = try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("settings.json"))) as? [String: Any]
                let local = try WorkspaceReplicaStore(directory: directory, initialWorkspaceID: UUID()).load()
                let localIDs = Set(local.revisions.map(\.id))
                let localHeads = Dictionary(uniqueKeysWithValues: local.records.map { ($0.id, Set($0.heads.map(\.id))) })
                let date = ISO8601DateFormatter()
                let peers = try await WorkspaceCloudTransport().publishedPeers()
                let rows: [[String: Any]] = peers.sorted { $0.name < $1.name }.map { peer in
                    let ids = Set(peer.replica.revisions.map(\.id))
                    let heads = Dictionary(uniqueKeysWithValues: peer.replica.records.map { ($0.id, Set($0.heads.map(\.id))) })
                    let differing = localHeads.filter { heads[$0.key] != $0.value }.map(\.key)
                    return ["name": peer.name, "platform": peer.platform, "deviceID": peer.deviceID.uuidString,
                            "revisions": ids.count, "records": peer.replica.records.count,
                            "conflicts": peer.replica.records.filter(\.isConflict).count,
                            "missingLocalRevisions": localIDs.subtracting(ids).count, "revisionsNotOnThisMac": ids.subtracting(localIDs).count,
                            "headsMatchingThisMac": localHeads.count - differing.count,
                            "newestRevision": peer.replica.revisions.map(\.createdAt).max().map(date.string) ?? NSNull(),
                            "differingRecordsSample": differing.prefix(20).map(\.uuidString)]
                }
                let output: [String: Any] = ["deviceID": settings?["deviceID"] ?? NSNull(), "localRevisions": localIDs.count,
                                             "localRecords": local.records.count, "peers": rows]
                print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            } catch {
                fputs("Unified peers: \(error.localizedDescription)\n", stderr); code = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(code)
    }
}
