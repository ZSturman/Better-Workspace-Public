import SwiftUI
import SwiftData
import CloudKit
import CoreData
import BetterWorkspaceCore

/// Shared native UI for the standalone Store experience and the advanced Mac app.
/// Opening a failed store never silently creates a replacement or memory-only store.
struct PersonalWorkspaceView: View {
    var sample = false
    var isolated = false
    @State private var container: ModelContainer?
    @State private var failure: String?
    @State private var cloudStatus = "Saved on this device · iCloud sync in the background"
    @Environment(\.scenePhase) private var scenePhase

    private var usesCloud: Bool { !sample && !isolated && WorkspaceNotebookPersistence.isCloudSyncEnabled }

    var body: some View {
        Group {
            if let container { PersonalWorkspaceHome(isSample: sample, usesCloud: usesCloud, cloudStatus: cloudStatus).modelContainer(container) }
            else if let failure {
                ContentUnavailableView { Label("Your workspace could not open", systemImage: "externaldrive.badge.exclamationmark") }
                    description: { Text(failure) }
                    actions: { Button("Try again") { self.failure = nil; load() } }
            } else { ProgressView("Opening your workspace…") }
        }
        .task { if container == nil { load() } }
        .task { @MainActor in
            guard usesCloud else { return }
            await refreshAccountStatus()
            for await notification in NotificationCenter.default.notifications(named: NSPersistentCloudKitContainer.eventChangedNotification) {
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { continue }
                if event.endDate == nil { cloudStatus = "Syncing with your private iCloud account…" }
                else if event.succeeded, let finished = event.endDate {
                    cloudStatus = "Last iCloud transfer finished at " + finished.formatted(date: .omitted, time: .shortened)
                } else {
                    let error = event.error as NSError?
                    let cloudError = (event.error as? CKError) ?? (error?.userInfo[NSUnderlyingErrorKey] as? CKError)
                    if cloudError?.code == .quotaExceeded {
                        cloudStatus = "iCloud storage is full. Work you save stays on this device."
                    } else {
                        cloudStatus = "iCloud transfer could not finish. Work you save stays here; check your connection and iCloud settings."
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if usesCloud && phase == .active { Task { await refreshAccountStatus() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            if usesCloud { Task { await refreshAccountStatus() } }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
        #endif
    }

    @MainActor private func load() {
        do {
            let store = try sample || isolated ? WorkspaceNotebookPersistence.container(inMemory: true) : WorkspaceNotebookPersistence.sharedContainer()
            if sample {
                let context = store.mainContext
                let project = WorkspaceNotebookRecord(kind: .project, title: "Garden journal", body: "Record small changes. Notice what grows.")
                context.insert(project)
                context.insert(WorkspaceNotebookRecord(kind: .task, title: "Sketch the weekly journal", body: "Leave room for the next small step.", projectID: project.recordID))
                context.insert(WorkspaceNotebookRecord(kind: .idea, title: "A reading nook for slow Sundays", body: "A comfortable chair, warm light and books worth returning to."))
                context.insert(WorkspaceNotebookRecord(kind: .document, title: "A note for the weekend", body: "Bring the journal outside. Notice one small change and write it down.", projectID: project.recordID))
                try context.save()
            }
            container = store
        } catch { failure = error.localizedDescription }
    }

    @MainActor private func refreshAccountStatus() async {
        do {
            switch try await CKContainer(identifier: MobileCloudSchema.containerIdentifier).accountStatus() {
            case .available: cloudStatus = "Saved on this device · private iCloud sync enabled. Changes can take a few minutes."
            case .noAccount: cloudStatus = "Saved on this device. Sign in to iCloud in system Settings to sync your personal workspace."
            case .restricted: cloudStatus = "Saved on this device. iCloud is restricted by this device’s settings."
            case .temporarilyUnavailable, .couldNotDetermine:
                cloudStatus = "Saved on this device. iCloud is temporarily unavailable; you can keep working offline."
            @unknown default: cloudStatus = "Saved on this device. Check iCloud availability in system Settings."
            }
        } catch {
            cloudStatus = "Saved on this device. iCloud is unavailable right now; you can keep working offline."
        }
    }
}

private struct NotebookDraft: Identifiable {
    let id = UUID()
    var record: WorkspaceNotebookRecord?
    var kind: WorkspaceNotebookKind = .idea
}

private struct PersonalWorkspaceHome: View {
    let isSample: Bool
    let usesCloud: Bool
    let cloudStatus: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WorkspaceNotebookRecord.modifiedAt, order: .reverse) private var records: [WorkspaceNotebookRecord]
    @State private var filter = "overview"
    @State private var query = ""
    @State private var draft: NotebookDraft?
    @State private var error: String?
    @State private var showsGuide = false
    @State private var showsSample = false

    private var visible: [WorkspaceNotebookRecord] {
        records.filter {
            ($0.isArchived == (filter == "archive")) &&
            (filter == "overview" || filter == "archive" || $0.kindValue == filter) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(isSample ? "Sample workspace · changes stay in this preview" : "Personal workspace · saved on this device", systemImage: isSample ? "sparkles" : "internaldrive")
                        .font(.footnote).foregroundStyle(.secondary)
                    if usesCloud { Text(cloudStatus).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("personal.cloud.status") }
                    Picker("Show", selection: $filter) {
                        Text("Overview").tag("overview")
                        ForEach(WorkspaceNotebookKind.allCases) { Text($0.title + "s").tag($0.rawValue) }
                        Text("Archive").tag("archive")
                    }.accessibilityIdentifier("personal.filter")
                    TextField("Find projects, tasks, ideas and documents", text: $query)
                        .accessibilityIdentifier("personal.search")
                    Menu {
                        ForEach(WorkspaceNotebookKind.allCases) { kind in
                            Button("New \(kind.title)", systemImage: kind.symbol) { draft = NotebookDraft(kind: kind) }
                                .accessibilityIdentifier("personal.new.\(kind.rawValue)")
                        }
                    } label: {
                        Label("Create", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(isSample ? "personal.sample.new" : "personal.new")
                }
                if visible.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label(query.isEmpty ? "Your next step starts here" : "No matching items", systemImage: "square.and.pencil")
                        } description: { Text(query.isEmpty ? "Create a project, capture an idea, or write a task. No setup or Mac connection is needed." : "Try another title or phrase.") }
                        if query.isEmpty && filter != "archive" {
                            Button("Create my first project", systemImage: "plus") { draft = NotebookDraft(kind: .project) }
                                .accessibilityIdentifier("personal.firstProject")
                            if !isSample {
                                Button("Try a private sample", systemImage: "sparkles") { showsSample = true }
                                    .accessibilityIdentifier("personal.sample.open")
                            }
                        }
                    }
                }
                if filter == "overview" {
                    if !visible.filter({ $0.kind == .task && !$0.isComplete }).isEmpty {
                        Section("Next up") { ForEach(visible.filter { $0.kind == .task && !$0.isComplete }.prefix(3)) { row($0) } }
                    }
                    Section("Your workspace") { ForEach(visible.filter { $0.kind != .task || $0.isComplete }) { row($0) } }
                } else {
                    Section { ForEach(visible) { row($0) } }
                }
                Section {
                    Text(isSample ? "Sample changes stay in this preview and are discarded when you close it. The sample does not open your personal records or send cloud changes." : usesCloud ? "Personal records stay in private app storage and synchronize through your private iCloud account when available. They work offline too. This workspace is separate from the Mac folder index and does not move existing files or send commands to a Mac." : "This personal workspace is saved privately on this device. It is separate from the Mac folder index and does not move existing files or send commands to a Mac. Personal iCloud sync is not enabled in this edition yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("My Workspace")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("Privacy & storage", systemImage: "lock.shield") { showsGuide = true }
                        if !isSample {
                            Button("Try a private sample", systemImage: "sparkles") { showsSample = true }
                                .accessibilityIdentifier("personal.sample.open")
                        }
                    } label: { Label("How it works", systemImage: "questionmark.circle") }
                    .accessibilityIdentifier("personal.options")
                }
            }
            .toolbar {
                if isSample { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("personal.sample.close") } }
            }
            .sheet(isPresented: $showsSample) { PersonalWorkspaceView(sample: true) }
            .sheet(item: $draft) { NotebookEditor(draft: $0) }
            .sheet(isPresented: $showsGuide) { NavigationStack { WorkspacePrivacyView() } }
            .alert("Couldn't save this change", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .accessibilityIdentifier("personal.workspace")
    }

    private func row(_ item: WorkspaceNotebookRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if item.kind == .task && !item.isArchived {
                Button {
                    item.isComplete.toggle(); item.modifiedAt = Date()
                    do { try context.save() } catch { context.rollback(); self.error = error.localizedDescription }
                } label: { Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle") }
                .buttonStyle(.borderless).accessibilityLabel(item.isComplete ? "Reopen task" : "Complete task")
            } else { Image(systemName: item.kind.symbol).foregroundStyle(.tint) }
            Button { draft = NotebookDraft(record: item, kind: item.kind) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).strikethrough(item.kind == .task && item.isComplete).foregroundStyle(.primary)
                    if !item.body.isEmpty { Text(item.body).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    if let projectID = item.projectID, let project = records.first(where: { $0.recordID == projectID }) {
                        Text(project.title).font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("personal.record.\(item.title)")
        .contextMenu {
            Button(item.isArchived ? "Restore" : "Archive", systemImage: item.isArchived ? "arrow.uturn.backward" : "archivebox") {
                do { try WorkspaceNotebookEditor.setArchived(!item.isArchived, record: item, in: context) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct NotebookEditor: View {
    let draft: NotebookDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var records: [WorkspaceNotebookRecord]
    @State private var title = ""
    @State private var text = ""
    @State private var projectID: UUID?
    @State private var originalDate: Date?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section(draft.kind.title) {
                    TextField("Title", text: $title).accessibilityIdentifier("personal.editor.title")
                    if draft.kind != .project {
                        Picker("Project", selection: $projectID) {
                            Text("None").tag(UUID?.none)
                            ForEach(records.filter { $0.kind == .project && !$0.isArchived }) { Text($0.title).tag(Optional($0.recordID)) }
                        }
                    }
                }
                Section("Notes · Markdown welcome") {
                    TextEditor(text: $text).frame(minHeight: 180).accessibilityIdentifier("personal.editor.body")
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("personal.editor.error") }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.record == nil ? "New \(draft.kind.title)" : "Edit \(draft.kind.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("personal.editor.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("personal.editor.save")
                }
            }
        }
        .interactiveDismissDisabled(!title.isEmpty || !text.isEmpty)
        .task {
            guard !loaded else { return }; loaded = true
            title = draft.record?.title ?? ""; text = draft.record?.body ?? ""
            projectID = draft.record?.projectID; originalDate = draft.record?.modifiedAt
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 450)
        #endif
    }

    private func save() {
        do {
            try WorkspaceNotebookEditor.save(in: context, record: draft.record, expectedModifiedAt: originalDate,
                kind: draft.kind, title: title, body: text, projectID: projectID)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
