import Foundation
import BetterWorkspaceCore

// Only seed a newly created, explicitly named disposable screenshot root.
guard CommandLine.arguments.count == 2 else { fatalError("Pass a new bw-store-* temporary directory") }
let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard root.lastPathComponent.hasPrefix("bw-store-"), root.path.hasPrefix("/private/tmp/") || root.path.hasPrefix("/tmp/") else {
    fatalError("The sample root must be a bw-store-* directory under /tmp")
}
let fm = FileManager.default
let workspace = root.appendingPathComponent("Workspace")
guard !fm.fileExists(atPath: workspace.path) else { fatalError("Sample workspace already exists") }
for area in ["Projects/Garden journal", "To Do", "Ideas/Reading nook"] {
    try fm.createDirectory(at: workspace.appendingPathComponent(area), withIntermediateDirectories: true)
}
for directory in ["Inbox", "Service"] {
    try fm.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
}
try "# Garden journal\n\nRecord small changes. Notice what grows.\n".write(to: workspace.appendingPathComponent("Projects/Garden journal/README.md"), atomically: true, encoding: .utf8)
try "# Reading nook\n\nA comfortable chair, warm light and books worth coming back to.\n".write(to: workspace.appendingPathComponent("Ideas/Reading nook/README.md"), atomically: true, encoding: .utf8)
let db = try Database(url: root.appendingPathComponent("sample.sqlite"))
let projects = ProjectStore(database: db)
let project = projects.register(url: workspace.appendingPathComponent("Projects/Garden journal"))
projects.setDescription(ProjectDescription(oneLiner: "A little more attention to what is growing.", summary: "Capture plant care, seasonal photos and observations in a portable garden journal."), for: project.id)
projects.setRating(4, metricID: "qualityOfLife", for: project.id)
let service = WorkItemService()
_ = try service.create(WorkItem(id: "sample-layout", kind: .task, title: "Sketch the weekly journal", stage: .now,
    priority: .high, projectPath: "Projects/Garden journal",
    body: "## The next small step\n\nDesign a weekly page that makes plant care easy to follow.\n\n- [ ] Sketch the watering log\n- [ ] Leave space for a photo\n- [x] Choose the plants to track", url: root),
    in: workspace.appendingPathComponent("To Do"))
_ = try service.create(WorkItem(id: "sample-photos", kind: .feature, title: "Plan the photo timeline", stage: .next,
    priority: .medium, projectPath: "Projects/Garden journal", body: "Keep a record of how the garden changes through the seasons.", url: root),
    in: workspace.appendingPathComponent("To Do"))
let ideas: [String: Any] = ["data": [["id": "sample-reading", "title": "A reading nook for slow Sundays",
    "path": workspace.appendingPathComponent("Ideas/Reading nook").path,
    "one_liner": "A comfortable place for the books worth coming back to.",
    "planning": ["priority": 4, "ratings": ["qualityOfLife": 4], "potential": "project", "needsSetup": false]]]]
try JSONSerialization.data(withJSONObject: ideas).write(to: root.appendingPathComponent("Service/v1_ideas.json"))
print(root.path)
