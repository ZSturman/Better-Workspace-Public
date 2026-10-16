import SwiftUI
import UniformTypeIdentifiers
import BetterWorkspaceCore

/// The execution surface is intentionally compact: it makes the next concrete item
/// visible before the surrounding planning information.  Project detail views can
/// reuse this same file-backed data without introducing a second task store.
struct WorkItemsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var kind: WorkItemKind?
    @State private var showingNewItem = false
    @State private var moving: WorkItem?
    @State private var showingMovePicker = false

    private var visibleItems: [WorkItem] {
        model.workItems.filter { item in
            (kind == nil || item.kind == kind) &&
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.projectPath?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { visibleItems.isEmpty && model.isAwaitingWorkItems }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "Work", subtitle: nil,
                       symbol: "checklist", count: showsLoading ? nil : visibleItems.filter(\.isOpen).count) {
                HStack(spacing: Theme.Space.snug) {
                    InlineSearchField(text: $query, prompt: "Filter work")
                    Menu {
                        Button("All types") { kind = nil }
                        Divider()
                        ForEach(WorkItemKind.allCases) { candidate in
                            Button(candidate.displayName) { kind = candidate }
                        }
                    } label: { Label(kind?.displayName ?? "All types", systemImage: "line.3.horizontal.decrease.circle") }
                    .menuStyle(.borderlessButton)
                    Button { showingNewItem = true } label: { Label("New", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
            Divider()
            if !showsLoading, !visibleItems.isEmpty {
                // Progress of what is listed (filters included), and the pace of finishing it.
                HStack(alignment: .bottom, spacing: Theme.Space.loose) {
                    WorkProgressStrip(counts: WorkProgressCounts(visibleItems))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("work.progress")
                    WeeklyActivityChart(counts: WeeklyCounts(dates: visibleItems.compactMap(\.completedAt), weeks: 12),
                                        title: "Completed, 12 weeks", color: .green, height: 28)
                        .frame(width: 220)
                        .accessibilityIdentifier("work.completions")
                }
                .padding(.horizontal, Theme.Space.base).padding(.vertical, Theme.Space.snug)
                Divider()
            }
            if let focusedPath = model.focusedWorkItemPath,
               let item = model.workItems.first(where: { $0.url.canonicalPath == focusedPath }) {
                FocusedWorkItem(item: item)
                Divider()
            }
            if showsLoading {
                LoadingAreaState(title: "Loading work items…", message: "Looking for work items across the Workspace.")
            } else if visibleItems.isEmpty {
                ContentUnavailableView("No work items", systemImage: "checklist",
                                       description: Text("Create one, or add a .bw.md file in Finder."))
            } else {
                List(visibleItems) { item in
                    let isCompleting = model.isPendingCompletion(item)
                    let isComplete = item.status == .completed || isCompleting
                    HStack(spacing: Theme.Space.base) {
                        Button { model.completeWorkItem(item) } label: {
                            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isComplete ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isCompleting ? "Undo completion" : (isComplete ? "Reopen" : "Mark complete"))
                        .accessibilityIdentifier("workItem.complete.\(item.id)")
                        Image(systemName: item.kind.symbolName).foregroundStyle(.tint).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).strikethrough(isComplete).lineLimit(1)
                            HStack(spacing: Theme.Space.tight) {
                                WorkStatusChip(item: item)
                                if let project = item.projectPath { Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                        Spacer()
                        if item.kind == .task {
                            Button(role: .destructive) { model.requestDeletion(of: item) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Move to Trash")
                                .accessibilityIdentifier("workItem.delete.\(item.id)")
                        }
                        if let due = item.dueDate { Text(due, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.inspect(workItem: item) }
                    .contextMenu {
                        Button("Open in default editor") { model.open(item.url) }
                        Button("Edit…") { model.edit(workItem: item) }
                        Button("Move…") { moving = item; showingMovePicker = true }
                        Divider()
                        WorkDeletionMenu(item: item) { model.requestDeletion(of: $0) }
                        if item.status != .completed { Button(isCompleting ? "Undo completion" : "Mark complete") { model.completeWorkItem(item) } }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showingNewItem) {
            WorkItemEditor(mode: .create) { value in try await model.createWorkItem(value) }
        }
        .fileImporter(isPresented: $showingMovePicker, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result, let moving else { return }
            model.moveWorkItem(moving, to: url)
            self.moving = nil
        }
        .task(id: model.focusedWorkItemPath) { @MainActor in
            guard let path = model.focusedWorkItemPath,
                  let item = model.workItems.first(where: { $0.url.canonicalPath == path }) else { return }
            model.inspect(workItem: item)
        }
    }
}

private struct FocusedWorkItem: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.base) {
            Image(systemName: item.kind.symbolName)
                .foregroundStyle(.tint)
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected from Overview")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(focusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.tight)
            Button("Open file") { model.open(item.url) }
            if item.projectPath != nil {
                Button("Go to project") { model.revealProject(for: item) }
            }
        }
        .padding(.horizontal, Theme.Space.loose)
        .padding(.vertical, Theme.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityIdentifier("work.focused.\(item.id)")
    }

    private var focusDetail: String {
        var parts = [item.kind.displayName, item.stage.displayName, item.priority.rawValue.capitalized + " priority"]
        if let project = item.projectPath { parts.append(project) }
        return parts.joined(separator: " · ")
    }
}

private struct WorkStatusChip: View {
    let item: WorkItem
    var body: some View {
        Text(item.status == .completed ? "Completed" : item.stage.displayName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(item.status == .completed ? Color.green : Color.secondary)
    }
}
