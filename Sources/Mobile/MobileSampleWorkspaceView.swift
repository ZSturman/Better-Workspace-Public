import SwiftUI
import BetterWorkspaceCore

/// Real workspace screens with bundled, read-only examples for first-time browsing.
struct MobileSampleWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = MobileWorkspaceModel(sampleSnapshot: MobileWorkspaceSample.snapshot())
    @State private var tab: MobileWorkspaceTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sample workspace").font(.headline).accessibilityIdentifier("workspace.sample.title")
                    Text("Read-only · No iCloud or Mac connection needed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.accessibilityIdentifier("workspace.sample.close")
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            MobileWorkspaceRootView(selectedTab: $tab, captureRequest: 0)
                .environment(model)
        }
    }
}

enum MobileWorkspaceSample {
    static func snapshot() -> MobileWorkspaceSnapshot {
        let now = Date()
        let project = "Projects/Garden journal"
        let work = [
            MobileWorkItem(id: "sample-layout", path: project + "/Work/Sketch.bw.md",
                title: "Sketch the weekly journal", kind: .task, status: .open, stage: .now,
                priority: .high, projectPath: project, revision: 1, tagIDs: ["sample-design"],
                body: "## The next small step\n\nDesign a weekly page that makes plant care easy to follow.\n\n- [ ] Sketch the watering log\n- [ ] Leave space for a photo\n- [x] Choose the plants to track",
                createdAt: now.addingTimeInterval(-7 * 86400), modifiedAt: now),
            MobileWorkItem(id: "sample-photos", path: project + "/Work/Photos.bw.md",
                title: "Plan the photo timeline", kind: .feature, status: .open, stage: .next,
                priority: .medium, projectPath: project, revision: 1,
                body: "Keep a simple record of how the garden changes through the seasons."),
            MobileWorkItem(id: "sample-brief", path: project + "/Work/Brief.bw.md",
                title: "Write the project brief", kind: .task, status: .completed, stage: .later,
                priority: .medium, projectPath: project, revision: 1,
                body: "A quiet place to keep growing notes.", completedAt: now.addingTimeInterval(-86400)),
        ]
        var snapshot = MobileWorkspaceSnapshot(
            tags: [Tag(id: "sample-design", name: "Design", colorIndex: 1, createdAt: now),
                   Tag(id: "sample-personal", name: "Personal", colorIndex: 3, createdAt: now)],
            entries: [MobileWorkspaceEntry(path: project, parentPath: "Projects", name: "Garden journal",
                isDirectory: true, revision: 1, tagIDs: ["sample-personal"], modifiedAt: now,
                projectDetails: MobileProjectDetails(path: project, oneLiner: "A little more attention to what is growing.",
                    summary: "Capture plant care, seasonal photos and observations in a portable garden journal.",
                    status: "Active", phase: "Planning", taskCount: 2, featureCount: 1,
                    projectID: "sample-garden", ratings: ["qualityOfLife": 4, "personalMeaning": 4],
                    scoringPreferences: ProjectScoringPreferences(), needsSetup: false,
                    previews: [MobileFilePreview(path: project + "/README.md", name: "README.md",
                        text: "# Garden journal\n\nRecord small changes. Notice what grows.\n\nThis is bundled sample content.")]))],
            workItems: work,
            ideas: [MobileIdea(path: "Ideas/Reading nook", title: "A reading nook for slow Sundays", revision: 1,
                tagIDs: ["sample-personal"], modifiedAt: now,
                description: "A comfortable chair, warm light and a shelf for the books worth coming back to.",
                serviceID: "sample-reading", planning: IdeaPlanning(priority: 4, ratings: ["qualityOfLife": 4], potential: .project),
                scoringPreferences: ProjectScoringPreferences()),
                MobileIdea(path: "Ideas/Walking notes.md", title: "Keep a walking notebook", revision: 1,
                    modifiedAt: now, description: "Collect a thought or a photograph after each walk.",
                    serviceID: "sample-walks", planning: IdeaPlanning(priority: 3, potential: .feature),
                    scoringPreferences: ProjectScoringPreferences())])
        snapshot.overview = OverviewDigest(focusItems: [
            OverviewFocusItem(id: project, path: project, title: "Garden journal", kind: .projects,
                              completed: 1, total: 3, lastWorked: now.addingTimeInterval(-86400)),
            OverviewFocusItem(id: "Ideas/Reading nook", path: "Ideas/Reading nook", title: "A reading nook for slow Sundays", kind: .ideas, lastChanged: now),
        ])
        return snapshot
    }
}
