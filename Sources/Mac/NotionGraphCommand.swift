import Foundation
import AppKit
import BetterWorkspaceCore

enum NotionGraphCommand {
    static func runIfRequested() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--notion") else { return }
        let args = CommandLine.arguments
        let command = args.indices.contains(flag + 1) ? args[flag + 1] : "status"
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task.detached {
            do {
                let store = try ProjectGraphStore(database: Database(url: Database.preferredURL()))
                if command == "check" {
                    guard (args.contains("--full") || TestIsolation.defaults.object(forKey: "projectGraphBackgroundChecks") as? Bool != false),
                          let token = SecretStore.read() else {
                        print("{\"skipped\":true,\"reason\":\"disabled_or_credentials_unavailable\"}"); semaphore.signal(); return
                    }
                    if !args.contains("--full"), let report = try store.read("report", as: ProjectSyncReport.self), let date = report.checkedAt, Date().timeIntervalSince(date) < 900 {
                        print("{\"skipped\":true,\"reason\":\"recent_check\"}"); semaphore.signal(); return
                    }
                    guard !NotionGraphConfiguration.seeds().isEmpty else { throw NotionProjectSync.SyncError.unsupported("Configure the Projects source in Settings → Integrations → Notion.") }
                    let result = try await NotionProjectSync(store: store, client: NotionClient(token: token)).check(seeds: NotionGraphConfiguration.seeds(), disabled: NotionGraphConfiguration.disabled(), forceFull: args.contains("--full"))
                    print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
                    if !result.failures.isEmpty { exitCode = 1 }
                } else if command == "handoff-service-writer" {
                    guard !TestIsolation.isActive, await BackgroundServiceClient.shared.claimProjectGraphWriter() else { throw NotionProjectSync.SyncError.unsupported("Install and start the current bundled service before handing off Notion writes.") }
                    try store.write("serviceWriterClaimed", true)
                    print("Service idea/work-log Notion writers handed off to reviewed project graph sync. Observation and API editing remain active.")
                } else if command == "validate-roundtrip" {
                    #if DEBUG
                    guard args.contains("--create-validation-records"), let token = SecretStore.read(), !TestIsolation.isActive else { throw NotionProjectSync.SyncError.unsupported("Developer validation requires --create-validation-records and a configured Notion token. It creates 12 named test pages and archives only those pages.") }
                    try await NotionGraphLiveValidation.run(client: NotionClient(token: token), configured: store.read("sources", as: [ProjectGraphSource].self) ?? [])
                    #else
                    throw NotionProjectSync.SyncError.unsupported("Live fixture validation is available only in developer builds.")
                    #endif
                } else if command == "audit-idea-projects" || command == "validate-idea-project" {
                    #if DEBUG
                    // Never block on a Keychain dialog in a headless run.
                    guard let token = SecretStore.read(interactive: false) ?? BackgroundServiceAgent().notionToken(), !TestIsolation.isActive else { throw NotionProjectSync.SyncError.unsupported("No Notion token is readable without a Keychain prompt.") }
                    if command == "audit-idea-projects" {
                        exitCode = try await NotionIdeaProjectValidation.audit(client: NotionClient(token: token), store: store)
                    } else {
                        guard args.contains("--create-validation-records") else { throw NotionProjectSync.SyncError.unsupported("validate-idea-project creates one named Projects page and archives only that page. Pass --create-validation-records to run it.") }
                        try await NotionIdeaProjectValidation.roundTrip(client: NotionClient(token: token), store: store, failing: NotionClient(token: "invalid-validation-token"))
                    }
                    #else
                    throw NotionProjectSync.SyncError.unsupported("Idea-project validation is available only in developer builds.")
                    #endif
                } else if command == "media-check" {
                    guard args.indices.contains(flag + 2) else { throw NotionProjectSync.SyncError.unsupported("Supply a project page ID to --notion media-check.") }
                    let pageID = args[flag + 2]
                    let sources = try store.read("sources", as: [ProjectGraphSource].self) ?? []
                    let snapshots = try store.records().map { record in var incoming = record; incoming.local = record.remote; return incoming }
                    guard let project = snapshots.first(where: { $0.kind == .projects && $0.pageID.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(pageID) }), let source = sources.first(where: { $0.id == project.sourceID }) else { throw NotionProjectSync.SyncError.unsupported("Check the Projects source first.") }
                    let local = try ProjectStore(database: Database(url: Database.preferredURL())).allRecords()
                    let roots = Dictionary(uniqueKeysWithValues: local.compactMap { item -> (String, URL)? in guard let id = item.notionPageID else { return nil }; return (ProjectGraph.normalizedID(id), URL(fileURLWithPath: item.lastPath)) })
                    var results: [[String: Any]] = []
                    for role in ["thumbnail", "poster", "hero", "banner", "icon"] {
                        let ids = project.value(role, source: source)["relation"].array.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID)
                        for asset in snapshots where asset.kind == .assets && asset.pageID.map(ProjectGraph.normalizedID).map(ids.contains) == true {
                            guard let assetSource = sources.first(where: { $0.id == asset.sourceID }) else { continue }
                            let media = ProjectMediaResolver.resolve(asset, source: assetSource, workspaceRoot: WorkspaceLocation.resolved.root, projectRoots: roots)
                            var result: [String: Any] = ["role": role, "asset": asset.title, "available": media.url != nil, "preview": media.isPreview, "staleLocalPath": media.staleLocalPath ?? ""]
                            if args.contains("--validate-preview"), let url = media.url {
                                let cached = try await ProjectPreviewCache.shared.file(for: url)
                                let image = NSImage(contentsOf: cached)
                                result["imageDecodes"] = image != nil
                                result["cachePath"] = cached.path
                            }
                            results.append(result)
                        }
                    }
                    print(String(decoding: try JSONSerialization.data(withJSONObject: ["project": project.title, "media": results], options: .sortedKeys), as: UTF8.self))
                } else if command == "status" {
                    var report = try store.read("report", as: ProjectSyncReport.self) ?? .init()
                    report.unresolvedReferences = try store.unresolvedReferences().count
                    report.referenceDetails = try store.referenceDetails(sources: store.read("sources", as: [ProjectGraphSource].self) ?? [])
                    let allRecords = try store.records()
                    let incoming = allRecords.filter { ($0.baseline.isEmpty && !$0.remote.isEmpty) || $0.remoteArchived != ($0.acknowledgedArchived ?? false) || $0.changes.contains { [.incoming, .conflict].contains($0.state) } }
                    let plan = ProjectSyncReviewPlan(records: incoming, allRecords: allRecords, sources: try store.read("sources", as: [ProjectGraphSource].self) ?? [])
                    var output = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any] ?? [:]
                    output["incomingReview"] = ["initialImport": plan.initialCount, "recommended": plan.recommendedIDs.count, "groups": Dictionary(uniqueKeysWithValues: ProjectSyncReviewPlan.Group.allCases.map { group in (group.title, plan.entries.filter { $0.group == group }.count) })] as [String: Any]
                    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: .sortedKeys), as: UTF8.self))
                } else { throw NotionProjectSync.SyncError.unsupported("Use --notion status|check [--full]|media-check <pageID> [--validate-preview]|audit-idea-projects. Sync writes require the app's review screen.") }
            } catch { print(error.localizedDescription); exitCode = 1 }
            semaphore.signal()
        }
        semaphore.wait(); exit(exitCode)
    }
}
