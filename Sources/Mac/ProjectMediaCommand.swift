import Foundation
import CryptoKit
import BetterWorkspaceCore

/// User-requested batch registration through the same importer as Add media file.
/// Files must already be classified into their project. This command never removes or sends files.
enum ProjectMediaCommand {
    struct Input: Decodable { let projectPath: String; let filePath: String; let sha256: String }
    static func runIfRequested() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--project-media") else { return }
        do {
            let args = CommandLine.arguments
            let root = args.firstIndex(of: "--workspace").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil } ?? WorkspaceLocation.resolved.root
            let database = try Database(url: Database.preferredURL()), store = try ProjectGraphStore(database: database)
            let locals = ProjectStore(database: database).allRecords()
            let records = try store.records(), sources = try store.read("sources", as: [ProjectGraphSource].self) ?? []
            guard args.indices.contains(flag + 1) else { throw CocoaError(.fileReadInvalidFileName) }
            if args[flag + 1] == "inspect" {
                let mediaIndex = ProjectGraphIndex(records: records, readingIncoming: true)
                let rows: [[String: Any]] = locals.filter { $0.url.deletingLastPathComponent().canonicalPath == root.appendingPathComponent("Projects").canonicalPath }.map { local in
                    let graph = records.first { $0.kind == .projects && ($0.localProjectID == local.id || (local.notionPageID != nil && $0.pageID.map(ProjectGraph.normalizedID) == local.notionPageID.map(ProjectGraph.normalizedID))) }
                    return ["projectPath": local.lastPath, "graphID": graph?.id ?? "", "mediaCount": graph.map { mediaIndex.related(to: $0).filter { $0.kind == .assets }.count } ?? 0]
                }
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["projects": rows, "sources": sources.map { ["id": $0.id, "kind": $0.kind.rawValue] }], options: .sortedKeys), as: UTF8.self))
            } else {
                guard args[flag + 1] == "register", args.indices.contains(flag + 2) else { throw CocoaError(.fileReadInvalidFileName) }
                let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: args[flag + 2])))
                let owner = "pid:\(ProcessInfo.processInfo.processIdentifier):\(UUID())"
                guard try store.acquire(owner: owner) else { throw NotionProjectSync.SyncError.busy }
                defer { try? store.release(owner: owner) }
                var receipts: [[String: Any]] = []
                var knownRecords = records
                for input in inputs {
                    do {
                        let projectURL = URL(fileURLWithPath: input.projectPath), file = URL(fileURLWithPath: input.filePath)
                        guard projectURL.deletingLastPathComponent().canonicalPath == root.appendingPathComponent("Projects").canonicalPath,
                              file.canonicalPath.hasPrefix(projectURL.canonicalPath + "/"),
                              let local = locals.first(where: { $0.url.canonicalPath == projectURL.canonicalPath }) else { throw CocoaError(.fileReadInvalidFileName) }
                        let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                        guard hash == input.sha256 else { throw CocoaError(.fileReadCorruptFile) }
                        if var graph = records.first(where: { $0.kind == .projects && ($0.localProjectID == local.id || (local.notionPageID != nil && $0.pageID.map(ProjectGraph.normalizedID) == local.notionPageID.map(ProjectGraph.normalizedID))) }) {
                            graph.localPath = local.lastPath
                            let asset = try ProjectMediaImport.register(file: file, project: graph, sources: sources, store: store, workspaceRoot: root, knownRecords: knownRecords)
                            if !knownRecords.contains(where: { $0.id == asset.id }) { knownRecords.append(asset) }
                            let resolverRoots = [ProjectGraph.normalizedID(graph.pageID ?? graph.id): projectURL]
                            guard let source = sources.first(where: { $0.id == asset.sourceID }),
                                  ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root, projectRoots: resolverRoots).url?.canonicalPath == file.canonicalPath else { throw CocoaError(.fileReadCorruptFile) }
                            receipts.append(["projectPath": input.projectPath, "filePath": input.filePath, "sha256": hash, "assetID": asset.id, "mode": "assets", "verified": true])
                        } else {
                            let allowed = [projectURL, projectURL.appendingPathComponent("Media"), projectURL.appendingPathComponent("docs/images")].map(\.canonicalPath)
                            guard allowed.contains(file.deletingLastPathComponent().canonicalPath) else { throw CocoaError(.fileReadInvalidFileName) }
                            receipts.append(["projectPath": input.projectPath, "filePath": input.filePath, "sha256": hash, "mode": "local-gallery", "verified": true])
                        }
                    } catch { receipts.append(["projectPath": input.projectPath, "filePath": input.filePath, "error": error.localizedDescription, "verified": false]) }
                }
                print(String(decoding: try JSONSerialization.data(withJSONObject: receipts, options: .sortedKeys), as: UTF8.self))
                if receipts.contains(where: { $0["verified"] as? Bool != true }) { exit(1) }
            }
            exit(0)
        } catch { fputs("Project media: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
