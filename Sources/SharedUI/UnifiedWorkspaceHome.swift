import SwiftUI
import TipKit
import BetterWorkspaceCore

/// Shared editor for the portable workspace. The filesystem browser remains an
/// additional capability; every item here has an identity independent of its title.
struct UnifiedWorkspaceHome: View {
    @Bindable var session: WorkspaceSession
    var showMacTools: (() -> Void)?
    var showSettings: (() -> Void)? = nil
    var projectHistory: ((UUID) -> ProjectWorkHistory?)? = nil
    var searchQuery: Binding<String>? = nil
    var synchronizesWhileVisible = true
    @State private var localQuery = ""
    @FocusState private var searchFocused: Bool
    private var query: String { searchQuery?.wrappedValue ?? localQuery }
    @State private var projectDomain = ""
    @State private var projectStatus = ""
    @State private var projectType = ""
    @State private var featuredOnly = false
    @State private var projectSort = "name"
    @State private var projectGroup = "none"
    @State private var kind: WorkspaceRecordContent.Kind?
    @State private var showingTrash = false
    @State private var editor: UnifiedEditorRequest?
    @State private var connections = false
    @State private var welcome = false
    @Environment(\.scenePhase) private var scenePhase

    private var visible: [WorkspaceRecordState] {
        session.records.filter { state in
            let content = state.resolved?.content ?? state.heads.first?.content
            guard let content else { return false }
            return (state.isConflict || content.isDeleted == showingTrash)
                && (kind == nil || content.kind == kind)
                && (kind != .project || ProjectViewQuery.matches(projectRow(state), query: "", filters: projectFilters))
                && (query.isEmpty || state.heads.contains { ($0.content.title + "\n" + $0.content.body).localizedCaseInsensitiveContains(query) })
        }.sorted { ProjectViewQuery.orderedBefore(projectRow($0), projectRow($1), sorts: [.init(field: kind == .project ? projectSort : "name")]) }
    }
    private var projectFilters: [ProjectPropertyFilter] {
        [("domain", projectDomain), ("status", projectStatus), ("type", projectType), ("featured", featuredOnly ? "Yes" : "")].filter { !$0.1.isEmpty }.map { .init(field: $0.0, values: [$0.1]) }
    }
    private func projectRow(_ state: WorkspaceRecordState) -> ProjectQueryRecord {
        let content = state.resolved?.content ?? state.heads.first?.content
        return ProjectProperties.queryRecord(id: state.id.uuidString, name: content?.title ?? "", metadata: content?.projectMetadata ?? .init(), portfolio: content?.projectLinks ?? .init())
    }
    private func projectOptions(_ field: String) -> [String] {
        Array(Set(session.records.filter { $0.resolved?.content.kind == .project }.flatMap { projectRow($0).selected(field) })).sorted()
    }
    private func projectFilter(_ title: String, field: String, value: Binding<String>) -> some View {
        Menu(title + (value.wrappedValue.isEmpty ? "" : ": " + value.wrappedValue)) {
            Button("All") { value.wrappedValue = "" }
            ForEach(projectOptions(field), id: \.self) { option in Button(option) { value.wrappedValue = option } }
        }
    }
    private func toggleFeatured(_ state: WorkspaceRecordState) {
        guard var content = state.resolved?.content else { return }
        var portfolio = content.projectLinks ?? .init(); portfolio.featured = !(portfolio.featured ?? false); content.projectLinks = portfolio
        Task { do { _ = try await session.save(recordID: state.id, content: content, expectedHeads: Set(state.heads.map(\.id))) } catch { session.error = error.localizedDescription } }
    }
    var body: some View {
        let displayTitles = session.displayTitles
        let locationIssues = session.locationIssues
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in your workspace", text: searchQuery ?? $localQuery)
                        .focused($searchFocused).submitLabel(.search)
                        .onSubmit { searchFocused = false }
                        .accessibilityIdentifier("unified.search")
                    Menu {
                        Button("All items") { kind = nil }
                        ForEach(WorkspaceRecordContent.Kind.allCases, id: \.self) { value in
                            Button(value.label) { kind = value }
                        }
                        Divider()
                        Toggle("Recently deleted", isOn: $showingTrash)
                    } label: { Label(kind?.label ?? "All items", systemImage: "line.3.horizontal.decrease.circle") }
                }.padding()
                if kind == .project {
                    ScrollView(.horizontal) {
                        HStack {
                            projectFilter("Domain", field: "domain", value: $projectDomain)
                            projectFilter("Status", field: "status", value: $projectStatus)
                            projectFilter("Type", field: "type", value: $projectType)
                            Toggle("Featured", isOn: $featuredOnly)
                            Picker("Sort", selection: $projectSort) { Text("Name").tag("name"); Text("Domain").tag("domain"); Text("Status").tag("status") }
                            Picker("Group", selection: $projectGroup) { Text("None").tag("none"); Text("Domain").tag("domain"); Text("Status").tag("status") }
                            Button("Reset") { projectDomain = ""; projectStatus = ""; projectType = ""; featuredOnly = false; projectSort = "name"; projectGroup = "none" }
                        }.font(.caption).padding(.horizontal).padding(.bottom, 8)
                    }
                }
                List {
                    if !session.pendingPeers.isEmpty {
                        Section {
                            Button { connections = true } label: {
                                Label("Connect device workspaces", systemImage: "arrow.triangle.merge")
                            }.accessibilityIdentifier("unified.reviewMerge")
                            Text("Your current items stay available. Review what will be combined before connecting.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !showingTrash && query.isEmpty && (!session.isFixture || UnifiedWorkspaceTipSetup.isRequested) {
                        Section {
                            if session.records.isEmpty { TipView(UnifiedCreateTip()) }
                            else if !session.cloudEnabled { TipView(UnifiedConnectTip()) { _ in connections = true } }
                        }
                    }
                    if visible.isEmpty {
                        ContentUnavailableView(showingTrash ? "No deleted items" : "Room for your next idea", systemImage: "square.stack.3d.up", description: Text(showingTrash ? "Deleted items can be restored here." : "Create a project, task, folder or note. Everything saves on this device, even offline."))
                            .listRowSeparator(.hidden)
                    }
                    let items = visible
                    let grouped = Dictionary(grouping: items) { state in kind == .project && projectGroup != "none" ? projectRow(state).selected(projectGroup).first ?? "Not set" : "" }
                    ForEach(grouped.keys.sorted(), id: \.self) { group in
                    Section {
                    ForEach(grouped[group] ?? []) { state in
                    HStack {

                        Button { editor = .init(state: state) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: state.isConflict ? "exclamationmark.arrow.triangle.2.circlepath" : (state.heads.first?.content.kind.symbol ?? "doc"))
                                    .foregroundStyle(state.isConflict ? Color.orange : Color.accentColor).frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(displayTitles[state.id] ?? state.heads.first?.content.title ?? "Item").foregroundStyle(.primary)
                                    if state.isConflict { Text("Review both versions").foregroundStyle(.orange).font(.caption) }
                                    else if let content = state.resolved?.content {
                                        Text(content.kind.label + (content.isComplete ? " · Completed" : "") + (content.responsibility.map { " · For " + $0 } ?? "") + (content.parentID.map { " · " + (displayTitles[$0] ?? "Waiting for parent") } ?? "")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let content = state.resolved?.content, content.kind == .project {
                                        HStack {
                                            ProjectDomainBadge(domain: content.projectMetadata?.domain)
                                            Text(content.projectMetadata?.status ?? "No status").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    if let issue = locationIssues[state.id] {
                                        Text("Location needs review: \(String(describing: issue))").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("unified.item." + state.id.uuidString)
                        if state.resolved?.content.kind == .project && !showingTrash {
                            Button { toggleFeatured(state) } label: { Image(systemName: state.resolved?.content.projectLinks?.featured == true ? "star.fill" : "star") }
                                .buttonStyle(.borderless).foregroundStyle(.yellow).accessibilityLabel("Toggle featured " + (state.resolved?.content.title ?? "project"))
                                .accessibilityValue(state.resolved?.content.projectLinks?.featured == true ? "Featured" : "Not featured")
                        }
                    }
                    }
                    } header: { if !group.isEmpty { Text(group) } }
                    }
                    Section {
                        Button { connections = true } label: { Label(session.status, systemImage: session.syncing ? "arrow.triangle.2.circlepath" : "externaldrive.badge.checkmark") }
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("unified.connectionStatus")
                        if let showMacTools { Button(action: showMacTools) { Label("Mac files & integrations", systemImage: "desktopcomputer") } }
                    }
                }.listStyle(.plain)
            }
            .navigationTitle("Workspace")
            .toolbar {
                if let showSettings {
                    ToolbarItem(placement: .automatic) {
                        Button(action: showSettings) { Label("Settings", systemImage: "gearshape") }.accessibilityIdentifier("workspace.settings")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editor = .init(state: nil) } label: { Label("New item", systemImage: "plus") }
                        .accessibilityIdentifier("unified.new")
                }
                if let showMacTools {
                    ToolbarItem(placement: .automatic) {
                        Button(action: showMacTools) { Label("Mac files & integrations", systemImage: "desktopcomputer") }
                            .accessibilityIdentifier("unified.macTools")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button { connections = true } label: { Label("Devices & recovery", systemImage: "icloud") }
                        .accessibilityIdentifier("unified.connections")
                }
            }
        }
        .sheet(item: $editor) { request in UnifiedWorkspaceEditor(session: session, state: request.state, history: request.state.flatMap { projectHistory?($0.id) }) }
        .sheet(isPresented: $connections) { UnifiedConnectionsView(session: session) }
        .sheet(isPresented: $welcome) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Image(systemName: "square.stack.3d.up.fill").font(.largeTitle).foregroundStyle(.tint)
                        Text(session.records.isEmpty ? "Start your workspace here" : "Your workspace is ready").font(.largeTitle.bold())
                        Text("Create projects, tasks, features, milestones, goals, ideas, folders and notes. Your changes save on this device and remain available offline.")
                        Text("A Mac is optional. Connecting devices through your private iCloud account lets you combine their workspaces after reviewing a merge. Both devices keep unique content, and a recovery checkpoint is saved first.")
                        Button("Start on this device") { finishWelcome(connect: false) }.buttonStyle(.borderedProminent).accessibilityIdentifier("unified.welcome.local")
                        Button("I already use Better Workspace on Mac") { finishWelcome(connect: true) }.accessibilityIdentifier("unified.welcome.connect")
                        Link("Download Better Workspace for Mac", destination: Self.downloadURL)
                        Text("Existing items from earlier versions are imported without removing the original data.").font(.footnote).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
                }.navigationTitle("Welcome")
            }.interactiveDismissDisabled()
            #if os(macOS)
            .frame(width: 560, height: 540)
            #endif
        }
        .alert("Workspace needs attention", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .task { @MainActor in
            welcome = !session.settings.welcomeCompleted
            if let id = session.focusedRecordID { openFocused(id) }
            guard synchronizesWhileVisible else { return }
            await session.synchronize()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                if scenePhase == .active { await session.synchronizeIfDue() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("BetterWorkspace.ShowWelcome"))) { _ in welcome = true }
        .onChange(of: session.settings.welcomeCompleted) { _, completed in if completed { welcome = false } }
        .onChange(of: session.focusedRecordID) { _, id in if let id { openFocused(id) } }
        .onChange(of: scenePhase) { _, value in if synchronizesWhileVisible && value == .active { Task { await session.synchronize() } } }
    }
    static let downloadURL = URL(string: "https://zacharysturman.com/better-workspace")!
    private func openFocused(_ id: UUID) {
        if let state = session.records.first(where: { $0.id == id }) { editor = .init(state: state) }
        session.focusedRecordID = nil
    }
    private func finishWelcome(connect: Bool) {
        do { try session.finishWelcome(); welcome = false; if connect { connections = true } }
        catch { session.error = error.localizedDescription }
    }
}

private struct UnifiedEditorRequest: Identifiable {
    let id = UUID()
    let state: WorkspaceRecordState?
}

struct UnifiedWorkspaceEditor: View {
    @Bindable var session: WorkspaceSession
    let state: WorkspaceRecordState?
    let history: ProjectWorkHistory?
    @Environment(\.dismiss) private var dismiss
    @State private var content: WorkspaceRecordContent
    @State private var selectedVersion: UUID?
    @State private var saving = false
    @State private var error: String?
    @State private var deleteConfirmation = false
    private let recordID: UUID
    private let expectedHeads: Set<UUID>

    init(session: WorkspaceSession, state: WorkspaceRecordState?, history: ProjectWorkHistory? = nil) {
        self.history = history
        self.session = session; self.state = state; recordID = state?.id ?? UUID()
        expectedHeads = Set(state?.heads.map(\.id) ?? [])
        _content = State(initialValue: state?.heads.first?.content ?? .init(kind: .task, title: ""))
    }
    var body: some View {
        NavigationStack {
            Form {
                if let state, state.isConflict {
                    Section("Concurrent changes") {
                        Text("Both versions were retained. Select a version to start from, edit it if needed, then save a resolution. A newer change will require another review.")
                        ForEach(state.heads) { revision in
                            Button {
                                content = revision.content; selectedVersion = revision.id
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(revision.origin.rawValue + " · " + revision.createdAt.formatted(), systemImage: selectedVersion == revision.id ? "checkmark.circle.fill" : "circle")
                                    Text(revision.content.title).font(.headline)
                                    Text(revision.content.isDeleted ? "Deleted on this device" : revision.content.body).lineLimit(8)
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("Title", text: $content.title).accessibilityIdentifier("unified.editor.title")
                    Picker("Kind", selection: $content.kind) {
                        ForEach(WorkspaceRecordContent.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.accessibilityIdentifier("unified.editor.kind")
                    Picker("Location", selection: $content.parentID) {
                        Text("Workspace").tag(nil as UUID?)
                        ForEach(parentCandidates) { parent in
                            Text(session.displayTitles[parent.id] ?? "Item").tag(parent.id as UUID?)
                        }
                        if let parentID = content.parentID, !parentCandidates.contains(where: { $0.id == parentID }) {
                            Text("Current location needs review").tag(parentID as UUID?)
                        }
                    }
                    Toggle("Completed", isOn: $content.isComplete)
                    if let owner = content.responsibility {
                        LabeledContent("For", value: owner).accessibilityIdentifier("unified.editor.responsibility")
                    }
                    if content.isDeleted { Toggle("In recently deleted", isOn: $content.isDeleted) }
                }
                if content.kind == .project {
                    Section("Project details") {
                        WorkspaceChoiceField("Domain", selection: metadataField(\.domain), suggestions: projectMetadataOptions(\.domain), store: TestIsolation.defaults)
                        if (content.projectMetadata?.domain ?? "").isEmpty { Text("Choose a domain to classify this project.").font(.caption).foregroundStyle(.secondary) }
                        WorkspaceChoiceField("Status", selection: metadataField(\.status), suggestions: projectMetadataOptions(\.status), store: TestIsolation.defaults)
                        ProjectTypeField(value: metadataField(\.projectType), suggestions: projectMetadataOptions(\.projectType), store: TestIsolation.defaults)
                        ProjectPortfolioFields(details: portfolioBinding)
                    }
                    Section("Links") { ProjectLinksFields(details: portfolioBinding) }
                    Section {
                        NavigationLink { ProjectWorkHistoryView(history: history) } label: {
                            Label("Work logs & sessions", systemImage: "clock.arrow.circlepath")
                        }.accessibilityIdentifier("project.history.open")
                    }
                }
                Section("Notes") {
                    TextEditor(text: $content.body).frame(minHeight: 180).accessibilityIdentifier("unified.editor.body")
                }
                if state != nil && !content.isDeleted {
                    Section { Button("Move to recently deleted", role: .destructive) { deleteConfirmation = true } }
                }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("unified.editor.error") } }
            }.formStyle(.grouped)
            .navigationTitle(state == nil ? "New item" : state!.isConflict ? "Resolve changes" : "Edit item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving || content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (state?.isConflict == true && selectedVersion == nil)).accessibilityIdentifier("unified.editor.save") }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 600, maxWidth: 760, minHeight: 420, idealHeight: 620, maxHeight: 720)
        #endif
        .confirmationDialog("Move this item to recently deleted?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("Move to recently deleted", role: .destructive) { content.isDeleted = true; save() }
        } message: { Text("The item stays recoverable. Its children keep their identities and are shown as needing a location review. Linked Mac files require their own reviewed Trash action.") }
    }
    private var portfolioBinding: Binding<ProjectPortfolioDetails> {
        Binding(get: { content.projectLinks ?? .init() }, set: { content.projectLinks = $0 })
    }
    private func metadataField(_ path: WritableKeyPath<ProjectMetadata, String?>) -> Binding<String> {
        Binding(get: { content.projectMetadata?[keyPath: path] ?? "" }, set: { value in
            var metadata = content.projectMetadata ?? .init(); metadata[keyPath: path] = value.isEmpty ? nil : value; content.projectMetadata = metadata
        })
    }
    private func projectMetadataOptions(_ path: KeyPath<ProjectMetadata, String?>) -> [String] {
        session.records.compactMap { $0.resolved?.content.projectMetadata?[keyPath: path] }
    }
    private var parentCandidates: [WorkspaceRecordState] {
        let titles = session.displayTitles
        return session.records.filter { $0.id != recordID && $0.resolved?.content.isDeleted == false && [.folder, .project, .feature, .milestone, .idea].contains($0.resolved!.content.kind) }
            .sorted { (titles[$0.id] ?? "") < (titles[$1.id] ?? "") }
    }
    private func save() {
        saving = true
        Task {
            do {
                if content.projectMetadata?.isEmpty == true { content.projectMetadata = nil }
                if content.projectLinks?.isEmpty == true { content.projectLinks = nil }
                if let portfolio = content.projectLinks { try ProjectProperties.validateChanges(portfolio, from: state?.resolved?.content.projectLinks ?? .init()) }
                _ = try await session.save(recordID: recordID, content: content, expectedHeads: expectedHeads, resolvingConflict: state?.isConflict == true)
                if !session.isFixture || UnifiedWorkspaceTipSetup.isRequested { UnifiedCreateTip().invalidate(reason: .actionPerformed) }
                dismiss()
            } catch { self.error = error.localizedDescription; saving = false }
        }
    }
}

struct UnifiedConnectionsView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var peer: WorkspaceCloudPeer?
    @State private var checkpoints: [URL] = []
    @State private var recovery: URL?
    var body: some View {
        NavigationStack {
            List {
                Section("Connect devices") {
                    Text("This " + session.deviceName + " · \(session.records.count) items")
                    Text(session.status).font(.caption).foregroundStyle(.secondary)
                    if session.cloudEnabled {
                        Button("Synchronize now") { Task { await session.synchronize() } }.disabled(session.syncing)
                        Button("Pause synchronization") { do { try session.pauseCloud() } catch { session.error = error.localizedDescription } }
                    } else {
                        Button("Connect using private iCloud") { Task { await session.enableCloud() } }.disabled(session.syncing || session.isFixture)
                            .accessibilityIdentifier("unified.enableCloud")
                    }
                    if let error = session.connectionError { Text(error).font(.caption).foregroundStyle(.orange) }
                    if let status = session.capabilityStatus { Text(status).font(.caption).foregroundStyle(.orange) }
                }
                if !session.pendingPeers.isEmpty {
                    Section("Workspaces ready to review") {
                        ForEach(session.pendingPeers) { value in
                            Button { peer = value } label: { Label("Review " + value.name + " workspace (\(value.replica.records.count) items)", systemImage: "arrow.triangle.merge") }
                        }
                    }
                }
                if !session.connectedPeers.isEmpty {
                    Section("Connected workspaces") {
                        ForEach(session.connectedPeers) { value in
                            Label(value.name + " · \(value.replica.records.count) items", systemImage: "checkmark.icloud")
                        }
                        Text("These are the last published workspaces. A device can be offline while you continue working here.").font(.caption)
                    }
                }
                if session.pendingPeers.isEmpty && session.connectedPeers.isEmpty {
                    Section("Other devices") {
                        Text(session.cloudEnabled ? "No other workspace has been discovered yet. Open Better Workspace on your other device, connect using the same iCloud account, then synchronize both devices." : "Connect using private iCloud to discover your other devices. A Mac is optional.")
                    }
                }
                Section("Recoverable merges") {
                    if checkpoints.isEmpty { Text("A private checkpoint is saved before every initial merge.").foregroundStyle(.secondary) }
                    ForEach(checkpoints, id: \.self) { checkpoint in
                        Button("Recover pre-merge items · " + String(checkpoint.deletingPathExtension().lastPathComponent.suffix(8))) { recovery = checkpoint }
                    }
                    Text("Recovery adds earlier versions without discarding later work. Differing edits appear for review.").font(.caption).foregroundStyle(.secondary)
                }
                Section("About device connections") {
                    Text("Use the same Apple account with iCloud enabled on each device. Initial workspace merges wait for your review. You can continue working offline.")
                    Text("On Mac, open Workspace in the sidebar and review Mac content to include its indexed projects and notes. Pairing devices alone does not include those files.").font(.caption)
                    Link("Download the optional Mac app", destination: UnifiedWorkspaceHome.downloadURL)
                    Text("The Mac adds filesystem browsing, integrations and selective file downloads. Development folders are not downloaded to your phone.").font(.caption)
                }
            }.navigationTitle("Devices & recovery")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 520)
        #endif
        .task { @MainActor in refreshCheckpoints() }
        .sheet(item: $peer, onDismiss: refreshCheckpoints) { UnifiedMergeReview(session: session, peer: $0) }
        .confirmationDialog("Recover earlier items?", isPresented: Binding(get: { recovery != nil }, set: { if !$0 { recovery = nil } }), titleVisibility: .visible) {
            Button("Recover items") { if let checkpoint = recovery { Task { do { try await session.recover(checkpoint) } catch { session.error = error.localizedDescription } }; recovery = nil } }
        }
    }
    private func refreshCheckpoints() { do { checkpoints = try session.checkpoints() } catch { session.error = error.localizedDescription } }
}

struct UnifiedMergeReview: View {
    @Bindable var session: WorkspaceSession
    let peer: WorkspaceCloudPeer
    var onApproved: (() async throws -> Void)?
    var additionalNotes: [String] = []
    @Environment(\.dismiss) private var dismiss
    @State private var preview: WorkspaceMergePreview?
    @State private var error: String?
    @State private var applying = false
    @State private var incoming: [WorkspaceRecordState] = []
    @State private var localIDs: Set<UUID> = []
    @State private var query = ""
    @State private var limit = 100
    private var matching: [WorkspaceRecordState] {
        incoming.filter { state in
            query.isEmpty || state.heads.contains { $0.content.title.localizedCaseInsensitiveContains(query) }
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Connect to " + peer.name).font(.title2.bold())
                    Text(onApproved != nil
                        ? "Include the indexed items below in your shared workspace. Finder remains the source of truth for their local files."
                        : "This connects the items saved on this device with those on " + peer.name + ". After you approve, updates between these devices sync automatically in the background.")
                    Text("Finder controls linked Mac files: deleting a task removes its entry, and moving a project to Ideas changes its kind. Connecting devices does not move or copy your folders. Notion changes require a separate review. A recovery checkpoint keeps earlier app records.")
                }
                if let preview {
                    Section("Items from this workspace") {
                        Text("\(incoming.filter { !localIDs.contains($0.id) }.count) new items · \(incoming.filter { localIDs.contains($0.id) }.count) already connected")
                        TextField("Find an item in this preview", text: $query).accessibilityIdentifier("unified.merge.search")
                        Text("\(preview.conflictRecordIDs.count) " + (preview.conflictRecordIDs.count == 1 ? "item" : "items") + " needing conflict review")
                        Text("\(preview.locationIssues.count) locations needing review")
                        ForEach(Array(matching.prefix(limit))) { record in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preview.displayTitles[record.id] ?? record.heads.first?.content.title ?? "Item")
                                Text((record.heads.first?.content.kind.label ?? "Item") + (localIDs.contains(record.id) ? " · Existing item" : " · New to this workspace"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if matching.count > limit { Button("Show more items") { limit += 100 } }
                    }
                }
                if !additionalNotes.isEmpty {
                    Section("Not included yet") { ForEach(additionalNotes.sorted(), id: \.self) { Text($0).font(.caption) } }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(onApproved != nil ? "Connect Mac files" : "Connect device workspaces")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() }.disabled(applying) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(onApproved != nil ? "Connect Mac files" : "Connect workspaces") {
                            guard let preview else { return }; applying = true
                            Task { do { _ = try await session.approve(peer, preview: preview); try await onApproved?(); dismiss() } catch { self.error = error.localizedDescription; await loadPreview(); applying = false } }
                        }.disabled(preview == nil || applying).accessibilityIdentifier("unified.merge.approve")
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 540)
        #endif
        .task { @MainActor in await loadPreview() }
    }
    @MainActor private func loadPreview() async {
        let store = session.store, peer = peer
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                (try store.previewMerge(peer.replica), peer.replica.records)
            }.value
            localIDs = Set(session.records.map(\.id)); incoming = loaded.1; preview = loaded.0
        } catch { self.error = error.localizedDescription }
    }
}

private struct UnifiedCreateTip: Tip {
    var title: Text { Text("Start with one item") }
    var message: Text? { Text("Use + to create a project, task or idea. It works offline; connecting a Mac is optional.") }
    var options: [Option] { [MaxDisplayCount(1)] }
}
private struct UnifiedConnectTip: Tip {
    var title: Text { Text("Bring your workspace to another device") }
    var message: Text? { Text("Connect with private iCloud when you are ready. You review existing workspaces before they are combined.") }
    var actions: [Action] { Action(id: "connect", title: "Devices & recovery") }
    var options: [Option] { [MaxDisplayCount(1)] }
}

extension WorkspaceRecordContent.Kind {
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .project: "shippingbox"; case .task: "checkmark.circle"; case .feature: "sparkles"
        case .milestone: "flag"; case .goal: "target"; case .idea: "lightbulb"; case .folder: "folder"; case .note: "doc.text"
        }
    }
}

/// Tips in acceptance runs have their own store, never the person’s dismissals.
enum UnifiedWorkspaceTipSetup {
    static var isRequested: Bool { WorkspaceSession.fixtureID != nil && TestIsolation.launchArgument("BWUnifiedShowTips") == "YES" }
    static func configureFixture() {
        guard isRequested else { return }
        do {
            let url = WorkspaceSession.storageDirectory.appendingPathComponent("Tips")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.url(url))])
        } catch { print("Isolated TipKit setup: \(error.localizedDescription)") }
    }
}
