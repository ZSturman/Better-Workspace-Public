import Foundation
import BetterWorkspaceCore

/// Local-only bridge for the resumable audit runner. There is deliberately no Send,
/// network, installation, or cleanup command in this interface.
enum ProjectAuditCommand {
    static func runIfRequested() {
        guard let index = CommandLine.arguments.firstIndex(of: "--project-audit") else { return }
        let args = CommandLine.arguments
        do {
            guard args.indices.contains(index + 1) else { throw ProjectAuditError.invalid("Use inspect|apply <manifest>|verify") }
            let workspace: WorkspaceLocation
            if let i = args.firstIndex(of: "--workspace"), args.indices.contains(i + 1) { workspace = .init(root: URL(fileURLWithPath: args[i + 1])) }
            else { workspace = .resolved }
            let database = try Database(url: Database.preferredURL())
            let projects = ProjectStore(database: database)
            let service = WorkItemService()
            let items = service.items(under: workspace.root)
            let output: Data
            switch args[index + 1] {
            case "inspect":
                let linked = try ProjectAuditLinkedWork.items(database: database, workspace: workspace, existing: items)
                let knownIDs = Set(items.map(\.id))
                let rows: [[String: Any]] = (items + linked.filter { !knownIDs.contains($0.id) }).map { item in
                    var row: [String: Any] = ["id":item.id, "title":item.title, "path":item.url.path,
                        "projectPath":item.projectPath ?? "", "status":item.status.rawValue,
                        "stage":item.stage.rawValue, "priority":item.priority.rawValue, "kind":item.kind.rawValue,
                        "body":item.body, "dependencies":item.dependencyIDs,
                        "modifiedAt":item.modifiedAt?.timeIntervalSince1970 ?? 0]
                    if let metadata = item.actionMetadata { row["metadata"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) }
                    if !knownIDs.contains(item.id) { row["linkedNotionID"] = item.id; row["linkedExpectedBody"] = item.body }
                    return row
                }
                output = try JSONSerialization.data(withJSONObject: ["workspace":workspace.root.path,
                    "workItems":rows, "projects":projects.allRecords().map { ["id":$0.id,"path":$0.lastPath,"notionPageID":$0.notionPageID ?? ""] }], options: [.sortedKeys])
            case "apply-many":
                guard args.indices.contains(index + 2) else { throw ProjectAuditError.invalid("Supply an audit manifest array") }
                let inputs = try JSONDecoder().decode([ProjectAuditImportInput].self, from: Data(contentsOf: URL(fileURLWithPath: args[index + 2])))
                let areas = AreaConfigurationStore(url: AreaConfigurationStore.defaultURL())
                let folders = WorkspaceFolderDiscovery().folders(in: workspace, store: areas) ?? []
                let queue = WorkQueueRouting.folder(for: .task, among: folders)?.url ?? workspace.url(forArea: "To Do")
                let importer = ProjectAuditImporter(database: database, reuseDiscovery: true)
                var results: [[String: Any]] = []
                for input in inputs {
                    do {
                        let receipt = try JSONSerialization.jsonObject(with: JSONEncoder().encode(importer.apply(input, workspace: workspace, queue: queue)))
                        results.append(["projectPath":input.projectPath, "receipt":receipt])
                    } catch { results.append(["projectPath":input.projectPath, "error":String(describing: error)]) }
                }
                output = try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys])
            case "apply":
                guard args.indices.contains(index + 2) else { throw ProjectAuditError.invalid("Supply an audit manifest") }
                let input = try JSONDecoder().decode(ProjectAuditImportInput.self, from: Data(contentsOf: URL(fileURLWithPath: args[index + 2])))
                let areas = AreaConfigurationStore(url: AreaConfigurationStore.defaultURL())
                let folders = WorkspaceFolderDiscovery().folders(in: workspace, store: areas) ?? []
                let queue = WorkQueueRouting.folder(for: .task, among: folders)?.url ?? workspace.url(forArea: "To Do")
                output = try JSONEncoder().encode(ProjectAuditImporter(database: database).apply(input, workspace: workspace, queue: queue))
            case "verify":
                let audits = try ProjectAuditStore(database: database)
                var rows: [[String: Any]] = []
                for project in projects.allRecords() where project.url.deletingLastPathComponent().canonicalPath == workspace.url(for: .projects).canonicalPath && !project.name.hasPrefix("_") {
                    guard let audit = try audits.assessment(for: project.id) else { continue }
                    let linked = items.filter { $0.projectPath == "Projects/" + project.name || $0.projectPath == project.lastPath }
                    let next = WorkItemRecommendation.nextAction(in: linked, allItems: items)
                    let agent = WorkItemRecommendation.nextAction(in: linked, allItems: items, audience: .agent)
                    let user = WorkItemRecommendation.nextAction(in: linked, allItems: items, audience: .user)
                    let duplicatePins = linked.filter { $0.isOpen && $0.actionMetadata?.isNextWork == true }.count > 1
                    rows.append(["project":project.name,"projectID":project.id,"todoCount":linked.count,
                        "nextWorkID":next?.id ?? "","nextAgentActionID":agent?.id ?? "","nextUserActionID":user?.id ?? "",
                        "valid":next?.id == audit.nextWorkID && !duplicatePins,
                        "classification":audit.classification])
                }
                output = try JSONSerialization.data(withJSONObject: ["projects":rows,"parsedWorkCount":items.count], options: [.sortedKeys])
            default: throw ProjectAuditError.invalid("Use --project-audit inspect|apply <manifest>|verify [--workspace <root>]")
            }
            print(String(decoding: output, as: UTF8.self)); exit(0)
        } catch { fputs("Project audit: \(String(describing: error)) — \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
