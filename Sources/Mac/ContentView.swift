import SwiftUI
import AppKit
import TipKit
import BetterWorkspaceCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingWorkspaceSetup = false
    @State private var inspectorWidth: CGFloat = 290
    @State private var inspectorDragStart: CGFloat?

    /// Sidebar (190) + detail (360) + inspector (250) needs 800pt before any padding.
    /// Below this the split view starts stealing width from the sidebar, which clipped
    /// its labels and collapsed the area header.
    private static let inspectorMinimumWindowWidth: CGFloat = 1000

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            shell(windowWidth: geometry.size.width)
        }
        #if DEBUG
        .overlay(alignment: .topTrailing) {
            if TestIsolation.isActive, TestIsolation.launchArgument("BWReliabilityResizeFixture") == "YES" {
                HStack {
                    Button("820") { resizeFixtureWindow(width: 820, height: 520) }.accessibilityIdentifier("reliability.resizeNarrow")
                    Button("1240") { resizeFixtureWindow(width: 1240, height: 820) }.accessibilityIdentifier("reliability.resizeWide")
                }.buttonStyle(.bordered).padding(8)
            }
        }
        #endif
        .sheet(item: Binding(get: { ["widget", "newProject"].contains(model.graphSyncReview?.presenterID ?? "") ? model.graphSyncReview : nil }, set: { model.graphSyncReview = $0 })) { review in
            ProjectSyncReviewView(review: review).environment(model)
        }
        .sheet(isPresented: $model.showingSyncCenter) { SyncCenterView().environment(model) }
        .sheet(item: $model.editingWorkItem) { item in WorkItemEditor(mode: .edit(item)).environment(model) }
        .sheet(item: $model.finderWorkDraft) { draft in
            WorkItemEditor(mode: .create, kind: draft.kind, projectPath: draft.projectPath) { value in
                try await model.createWorkItem(value)
            }.environment(model)
        }
        .sheet(item: $model.projectToolTarget) { target in
            ProjectToolSheet(target: target)
                .environment(model)
        }
        .sheet(isPresented: $showingWorkspaceSetup) {
            WorkspaceSetupView(root: model.workspace.root).environment(model)
        }
        .task { @MainActor in
            guard !TestIsolation.defaults.bool(forKey: "macWorkspaceSetupCompleted") else { return }
            let root = model.workspace.root
            let needsSetup = await Task.detached(priority: .utility) {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return true }
                return names.filter(WorkspaceFolderDiscovery.couldBeArea).isEmpty
            }.value
            if needsSetup { showingWorkspaceSetup = true }
        }
    }

    #if DEBUG
    private func resizeFixtureWindow(width: CGFloat, height: CGFloat) {
        let window = NSApp.windows.first { $0.isVisible && AppDelegate.isMainWorkspaceWindow($0) }
        window?.setContentSize(NSSize(width: width, height: height))
    }
    #endif

    private func shell(windowWidth: CGFloat) -> some View {
        @Bindable var model = model
        let roomForInspector = windowWidth >= Self.inspectorMinimumWindowWidth
        let focusedWork = !roomForInspector && model.showInspector && model.selectedItem.map { selected in
            model.workItems.contains { $0.url.canonicalPath == selected.url.canonicalPath }
        } == true
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            // A plain stack keeps the main list stable and lets it shrink when
            // the inspector disappears. NSSplitView retained old pane constraints;
            // replacing its identity during live resize crashed outgoing table rows.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if model.workspaceAvailable == false { unavailableBanner }
                    ZStack {
                        detail.opacity(focusedWork ? 0 : 1)
                            .allowsHitTesting(!focusedWork).accessibilityHidden(focusedWork)
                    if focusedWork {
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
                    }
                    }
                }
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                // The ingest classifier carries its own title/tag/destination editor, so
                // a second inspector beside it is 300 points of "Nothing selected".
                if model.showInspector, model.selection != .ingest, model.selection != .unified, !isRootSelection, roomForInspector,
                   model.selection != .folder("Projects") || model.selectedItem?.isDirectory == false {
                    inspectorDivider
                    InspectorView()
                        .frame(width: inspectorWidth).frame(maxHeight: .infinity)
                }
            }
            // Keep the main pane's identity stable across live resize/fullscreen.
            // Replacing the split tears down its NSTableView while AppKit is still
            // preparing outgoing rows, triggering ViewListTree.visitItem assertions.
            // Moving to another area must not leave the inspector describing an item
            // from the one you just left.
            .onChange(of: model.selection) { _, _ in
                // A new area starts with nothing selected, unless the navigation that
                // opened it named an item (AppModel.navigate(to:selecting:)).
                model.selectedItem = model.selectionAfterNavigation
                model.selectionAfterNavigation = nil
            }
                .toolbar {
                    ToolbarItem(id: "workspaceSetup", placement: .primaryAction) {
                        Button { showingWorkspaceSetup = true } label: {
                            Label("Workspace Setup", systemImage: "folder.badge.gearshape")
                        }.accessibilityIdentifier("workspace.setup")
                            .popoverTip(MacWorkspaceSetupTip(), arrowEdge: .bottom)
                    }
                    ToolbarItem(id: "notionSync", placement: .primaryAction) {
                        if !model.graphSources.isEmpty { SyncStatusButton() }
                    }

                    ToolbarItem(id: "inspector", placement: .primaryAction) {
                        Button { model.showInspector.toggle() } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .disabled(model.selection == .ingest || model.selection == .unified || isRootSelection || roomForInspector == false)
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
        .alert("Delete “\(model.deletionRequest?.title ?? "item")”?", isPresented: Binding(
            get: { model.deletionRequest != nil }, set: { if !$0 { model.deletionRequest = nil } }
        )) {
            Button("Move to Trash", role: .destructive) { model.confirmDeletion() }
            Button("Cancel", role: .cancel) { model.deletionRequest = nil }
        } message: { Text(model.deletionRequest?.message ?? "") }
        .overlay(alignment: .bottom) { statusBar }
    }

    private var inspectorDivider: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            .padding(.horizontal, 3).contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                if inspectorDragStart == nil { inspectorDragStart = inspectorWidth }
                inspectorWidth = min(400, max(250, (inspectorDragStart ?? inspectorWidth) - value.translation.width))
            }.onEnded { _ in inspectorDragStart = nil })
            .accessibilityLabel("Inspector width")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: inspectorWidth = min(400, inspectorWidth + 20)
                case .decrement: inspectorWidth = max(250, inspectorWidth - 20)
                @unknown default: break
                }
            }.help("Drag to resize the inspector")
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
        case .unified:
            MacUnifiedWorkspaceView()
        case .work:
            WorkItemsView()
        case .ingest:
            IngestView()
        case .rootItem(let name):
            if let item = model.rootItems.first(where: { $0.id == name }) {
                Group {
                    switch item.kind {
                    case .application: WorkspaceApplicationDetail(item: item)
                    case .webpage: WorkspaceWebpageDetail(item: item)
                    case .file: WorkspaceRootFileDetail(item: item)
                    }
                }.id(item.id)
            } else {
                EmptyAreaState(symbol: "doc.badge.ellipsis", title: "Item unavailable", message: "It may have moved or been removed. Refresh the workspace to update the sidebar.")
            }
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

    private var isRootSelection: Bool {
        if case .rootItem = model.selection { return true }; return false
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
                NavigationLink(value: SidebarSelection.unified) {
                    Label("Workspace", systemImage: "square.stack.3d.up")
                }.accessibilityIdentifier("sidebar.unified")
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

            if !model.rootItems.isEmpty {
                Section {
                    ForEach(model.rootItems) { item in
                        NavigationLink(value: SidebarSelection.rootItem(item.id)) {
                            Label(item.title, systemImage: item.symbol).lineLimit(1)
                        }.accessibilityIdentifier("sidebar.root." + item.id)
                            .contextMenu { Button("Show in Finder") { model.revealInFinder(item.url) } }
                    }
                } header: {
                    Text("Apps, Webpages & Files")
                } footer: {
                    TipView(WorkspaceRootItemsTip()).font(.caption)
                }
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
