import SwiftUI
import BetterWorkspaceCore

struct ProjectNotionConnection: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    @State private var linking = false
    @State private var query = ""
    @State private var error: String?

    private var linked: Bool { model.projectRecord(for: project)?.hasNotionLink == true }
    private var candidates: [ProjectGraphRecord] {
        model.graphRecords.filter {
            $0.kind == .projects && $0.pageID != nil && $0.localProjectID == nil && !$0.remoteArchived && !$0.archiveRequested && $0.locallyDeleted != true
                && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
        }.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(linked ? "Linked to Notion" : "Local project · Notion optional", systemImage: linked ? "link" : "folder")
            if let url = model.projectRecord(for: project)?.notionURL { Link("Open in Notion", destination: url) }
            if !linked {
                ViewThatFits(in: .horizontal) {
                    HStack { connectionButtons }
                    VStack(alignment: .leading) { connectionButtons }
                }
            }
            NotionSyncControls()
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .sheet(isPresented: $linking) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link an existing Notion project").font(.headline)
                Text("Choose the existing page for “\(project.displayTitle)”. Linking keeps local values and remote differences for Sync Center review; it does not create or send a page.").font(.callout)
                TextField("Find a Notion project", text: $query).textFieldStyle(.roundedBorder)
                List(candidates) { candidate in
                    HStack {
                        VStack(alignment: .leading) { Text(candidate.title); Text(candidate.pageID ?? "").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Link") {
                            Task { @MainActor in
                                do { try await model.linkExistingNotionProject(candidate, to: project); linking = false; error = nil }
                                catch { self.error = error.localizedDescription; linking = false }
                            }
                        }.disabled(model.graphBusy).accessibilityLabel("Link " + candidate.title)
                    }
                }
                if candidates.isEmpty { Text("No unlinked pages match. Check Notion for changes in Sync Center to load existing projects.").font(.caption) }
                Button("Cancel") { linking = false }.keyboardShortcut(.cancelAction)
            }.padding().frame(minWidth: 460, idealWidth: 560, minHeight: 380)
        }
        .sheet(item: Binding(get: { model.graphSyncReview?.presenterID == "projectConnection" ? model.graphSyncReview : nil }, set: { model.graphSyncReview = $0 })) {
            ProjectSyncReviewView(review: $0)
        }
    }

    @ViewBuilder private var connectionButtons: some View {
        Button("Link existing Notion project…") { query = ""; linking = true }
            .disabled(model.graphBusy).accessibilityIdentifier("project.notion.link")
        Button("Add to Notion…") {
            Task { @MainActor in
                do { try await model.reviewNewProjectInNotion(project, presenterID: "projectConnection"); error = nil }
                catch { self.error = error.localizedDescription }
            }
        }.disabled(model.graphBusy || !model.hasNotionToken).accessibilityIdentifier("project.notion.create")
    }
}

/// Visible entry points into existing manual/opt-in synchronization. Opening the
/// center does not transfer anything; Sync uses the established safe-change planner.
struct NotionSyncControls: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Sync with Notion", systemImage: "arrow.triangle.2.circlepath") { Task { await model.syncNow() } }
                    .disabled(model.graphBusy || !model.hasNotionToken).accessibilityIdentifier("notion.syncNow")
                Button("Open Sync Center") { model.showingSyncCenter = true }
            }
            if let activity = model.syncActivity {
                HStack { ProgressView().controlSize(.small); Text(activity).font(.caption) }
            } else {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let feedback = model.syncFeedback {
                Text(feedback).font(.caption).foregroundStyle(model.syncFeedbackIsError ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
            if let date = model.lastSuccessfulNotionSync ?? [model.syncReport, model.syncActionReport, model.syncLastChangesReport].compactMap({ $0 })
                .filter({ $0.failed.isEmpty && $0.readFailures.isEmpty }).compactMap(\.finishedAt).max() {
                Text("Last successful sync: \(date.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var status: String {
        switch model.notionSyncState {
        case .notConfigured: "Configure the optional Notion integration in Settings."
        case .syncing: "Syncing…"
        case .upToDate: model.graphReport == nil ? "Notion has not been checked yet." : "No pending Notion changes."
        case .waiting(let count): "\(count) changes are ready for synchronization."
        case .recovering(let count): "Retrying \(count) records after a failure."
        case .attention(let count): "\(count) records need review in Sync Center."
        case .unavailable(let message): message
        }
    }
}
