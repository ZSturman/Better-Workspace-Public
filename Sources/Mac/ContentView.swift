import SwiftUI
import BetterWorkspaceCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Sidebar (190) + detail (360) + inspector (250) needs 800pt before any padding.
    /// Below this the split view starts stealing width from the sidebar, which clipped
    /// its labels and collapsed the area header.
    private static let inspectorMinimumWindowWidth: CGFloat = 1000

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            shell(windowWidth: geometry.size.width)
        }
        .sheet(item: Binding(get: { model.graphSyncReview?.presenterID == "widget" ? model.graphSyncReview : nil }, set: { model.graphSyncReview = $0 })) { review in
            ProjectSyncReviewView(review: review).environment(model)
        }
        .sheet(isPresented: $model.showingSyncCenter) { SyncCenterView().environment(model) }
        .sheet(item: $model.editingWorkItem) { item in WorkItemEditor(mode: .edit(item)).environment(model) }
        .sheet(item: $model.projectToolTarget) { target in
            ProjectToolSheet(target: target)
                .environment(model)
        }
    }

    private func shell(windowWidth: CGFloat) -> some View {
        @Bindable var model = model
        let roomForInspector = windowWidth >= Self.inspectorMinimumWindowWidth
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            // Deliberately not `.inspector(isPresented:)`.
            //
            // That modifier bridges to an AppKit split-view controller which, once
            // accessibility-enhanced UI is switched on (VoiceOver, or anything driving
            // the app through the accessibility API), re-invalidates layout from inside
            // AppKit's update-constraints pass and aborts the process from
            // `-[NSWindow _postWindowNeedsUpdateConstraints]`. Reproduced reliably under
            // XCUITest; an `HSplitView` gives the same resizable trailing pane and is
            // stable. See README "Problems found".
            HSplitView {
                VStack(spacing: 0) {
                    if model.workspaceAvailable == false { unavailableBanner }
                    if !roomForInspector, model.showInspector,
                       let selected = model.selectedItem,
                       model.workItems.contains(where: { $0.url.canonicalPath == selected.url.canonicalPath }) {
                        // At narrow widths the trailing inspector cannot fit. Keep
                        // a linked task/feature/milestone visible as the main screen.
                        VStack(spacing: 0) {
                            HStack {
                                Button {
                                    model.selectedItem = nil
                                    model.focusedWorkItemPath = nil
                                } label: { Label("Back to list", systemImage: "chevron.left") }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("work.detail.back")
                                Spacer()
                            }.padding(Theme.Space.base)
                            Divider()
                            InspectorView()
                        }
                    } else {
                        detail
                    }
                }
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                // The ingest classifier carries its own title/tag/destination editor, so
                // a second inspector beside it is 300 points of "Nothing selected".
                if model.showInspector, model.selection != .ingest, roomForInspector,
                   model.selection != .folder("Projects") || model.selectedItem?.isDirectory == false {
                    InspectorView()
                        .frame(minWidth: 250, idealWidth: 290, maxWidth: 400, maxHeight: .infinity)
                }
            }
            // Shrinking below the inspector threshold removes its pane, and HSplitView
            // then kept the detail pane at its old width: launching at a restored 1400pt
            // frame and resizing to 820pt left Overview running off the window. A new
            // identity when the pane comes or goes lays the split out afresh.
            .id(roomForInspector)
            // Moving to another area must not leave the inspector describing an item
            // from the one you just left.
            .onChange(of: model.selection) { _, _ in
                // A new area starts with nothing selected, unless the navigation that
                // opened it named an item (AppModel.navigate(to:selecting:)).
                model.selectedItem = model.selectionAfterNavigation
                model.selectionAfterNavigation = nil
            }
                .toolbar {
                    ToolbarItem(id: "notionSync", placement: .primaryAction) {
                        if !model.graphSources.isEmpty { SyncStatusButton() }
                    }

                    ToolbarItem(id: "inspector", placement: .primaryAction) {
                        Button { model.showInspector.toggle() } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .disabled(model.selection == .ingest || roomForInspector == false)
                        .help(roomForInspector
                              ? "Show or hide the inspector"
                              : "The window is too narrow for the inspector")
                    }
                    ToolbarItem(id: "refresh", placement: .primaryAction) {
                        Button { Task { await model.checkWorkspaceAvailability(); await model.refreshAll() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                    }
                }
        }
        .navigationTitle("")
        .alert("Workspace files changed outside Better Workspace", isPresented: Binding(
            get: { model.workItemSyncPrompt != nil },
            set: { if $0 == false { model.dismissWorkItemSyncPrompt() } }
        )) {
            Button("Add files back") { model.restoreMissingWorkItems() }
            Button("Sync app to folder", role: .destructive) { model.syncWorkItemsToFolder() }
            Button("Later", role: .cancel) { model.dismissWorkItemSyncPrompt() }
        } message: {
            Text(model.workItemSyncPrompt?.message ?? "The Workspace no longer matches the tasks currently shown in the app.")
        }
        .alert("Delete “\(model.deletionRequest?.title ?? "item")”?", isPresented: Binding(
            get: { model.deletionRequest != nil }, set: { if !$0 { model.deletionRequest = nil } }
        )) {
            Button("Move to Trash", role: .destructive) { model.confirmDeletion() }
            Button("Cancel", role: .cancel) { model.deletionRequest = nil }
        } message: { Text(model.deletionRequest?.message ?? "") }
        .overlay(alignment: .bottom) { statusBar }
    }

    /// Says the Workspace is missing rather than letting every area look emptied.
    private var unavailableBanner: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("The Workspace folder isn't available").font(.system(size: 12, weight: .semibold))
                Text("\(model.workspace.root.path) — a disconnected drive, or moved. Showing what was last seen; "
                     + "it reloads by itself when the folder is back.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
        .background(Color.orange.opacity(0.10))
        .accessibilityIdentifier("workspace.unavailable")
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview, .none:
            OverviewView()
        case .work:
            WorkItemsView()
        case .ingest:
            IngestView()
        case .tag(let id):
            if let tag = model.allTags.first(where: { $0.id == id }) {
                TagBrowserView(tag: tag)
            } else {
                EmptyAreaState(symbol: "tag", title: "Tag not found", message: "It may have been deleted.")
            }
        case .folder(let name):
            if let folder = model.folder(named: name) {
                AreaView(folder: folder)
                    // A different folder is a different area: reset search and sheets.
                    .id(folder.name)
            } else if model.folders.isEmpty && model.workspaceAvailable == false {
                // Not loading: there is nothing to load until the folder is back.
                EmptyAreaState(symbol: "externaldrive.badge.exclamationmark", title: "Workspace unavailable",
                               message: "\(name) will open when the Workspace folder is back.")
            } else if model.folders.isEmpty {
                // Discovery has not answered yet on launch; not the same as missing.
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyAreaState(symbol: "folder.badge.questionmark", title: "Folder not found", message: "It may have been moved or removed in Finder.")
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if let message = model.statusMessage ?? model.lastError {
            let isError = model.lastError != nil
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .orange : .green)
                Text(message).font(.system(size: 12))
                Spacer()
                Button {
                    model.statusMessage = nil
                    model.lastError = nil
                } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.Space.snug)
            .padding(.vertical, Theme.Space.tight)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
            // Clear of the ingest pane's Skip / File it row, which it used to cover.
            .padding(.horizontal, Theme.Space.base)
            .padding(.bottom, Theme.Space.section + Theme.Space.snug)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(5))
                withAnimation {
                    model.statusMessage = nil
                    model.lastError = nil
                }
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewTag = false
    @State private var showingHiddenFolders = false
    @State private var settingsFolder: WorkspaceFolder?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                NavigationLink(value: SidebarSelection.overview) {
                    Label("Overview", systemImage: "rectangle.3.group")
                }
                NavigationLink(value: SidebarSelection.ingest) {
                    HStack(spacing: Theme.Space.tight) {
                        Image(systemName: "tray.and.arrow.down")
                            .foregroundStyle(model.unprocessedIngestCount > 0 ? Color.accentColor : .secondary)
                        Text("Ingest")
                        Spacer()
                        if model.unprocessedIngestCount > 0 {
                            Text("\(model.unprocessedIngestCount)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(model.pendingIngestCount > 0
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.55),
                                            in: Capsule())
                        }
                    }
                }
                .accessibilityIdentifier("sidebar.ingest")
            } header: {
                Text("Inbox")
            }

            Section {
                ForEach(visibleFolders) { folder in
                    folderRow(folder)
                }
                if hiddenFolders.isEmpty == false {
                    DisclosureGroup(isExpanded: $showingHiddenFolders) {
                        ForEach(hiddenFolders) { folder in
                            folderRow(folder)
                        }
                    } label: {
                        Text("Hidden (\(hiddenFolders.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("sidebar.hiddenFolders")
                }
            } header: {
                Text("Workspace")
            }

            Section {
                if model.allTags.isEmpty {
                    Text("No tags yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(model.allTags) { tag in
                        NavigationLink(value: SidebarSelection.tag(tag.id)) {
                            HStack(spacing: Theme.Space.tight) {
                                Circle().fill(Theme.tagColor(tag)).frame(width: 7, height: 7)
                                Text(tag.name).lineLimit(1)
                                Spacer()
                                Text("\(model.tagUsage[tag.id] ?? 0)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityIdentifier("sidebar.tag.\(tag.name)")
                        .contextMenu {
                            Button("Delete Tag", role: .destructive) { model.deleteTag(tag) }
                        }
                    }
                }
                if showingNewTag {
                    NewTagField(
                        allTags: model.allTags,
                        onCreate: { model.createTag(named: $0) },
                        onShow: { model.selection = .tag($0.id) },
                        onDone: { showingNewTag = false }
                    )
                } else {
                    Button {
                        showingNewTag = true
                    } label: {
                        Label("New Tag", systemImage: "plus").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Tags")
            } footer: {
                Text(model.workspace.root.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help("Workspace root — the source of truth")
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $settingsFolder) { folder in
            AreaSettingsSheet(folder: folder)
        }
    }

    private var visibleFolders: [WorkspaceFolder] { model.folders.filter { $0.settings.hidden == false } }
    private var hiddenFolders: [WorkspaceFolder] { model.folders.filter(\.settings.hidden) }

    private func folderRow(_ folder: WorkspaceFolder) -> some View {
        NavigationLink(value: SidebarSelection.folder(folder.name)) {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: folder.settings.symbol).frame(width: 16)
                Text(folder.name).lineLimit(1)
                if folder.isUnfamiliar {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        .help("New folder — not set up yet")
                }
                Spacer()
                Text(folderCount(folder))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("sidebar.folder.\(folder.name)")
        .contextMenu {
            Button("Area Settings…") { settingsFolder = folder }
            Button(folder.settings.hidden ? "Show in Sidebar" : "Hide from Sidebar") {
                var personal = folder.personal
                let hide = folder.settings.hidden == false
                personal.hidden = hide == (AreaDefaults.configuration(forFolderNamed: folder.name).hidden ?? false)
                    ? nil : hide
                model.setConfiguration(personal, for: folder)
            }
            Divider()
            Button("Show in Finder") { model.revealInFinder(folder.url) }
        }
    }

    /// Open work for a work queue, since that is what the area is for; immediate
    /// children for everything else.
    private func folderCount(_ folder: WorkspaceFolder) -> String {
        if folder.settings.layout == .workQueue {
            let root = folder.url.canonicalPath + "/"
            let open = model.workItems.filter { $0.isOpen && $0.url.canonicalPath.hasPrefix(root) }.count
            return open == 0 ? "" : "\(open)"
        }
        let count = model.items(inArea: folder.name).count
        return count == 0 ? "" : "\(count)"
    }
}
