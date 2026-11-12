import SwiftUI
import AppKit
import TipKit
import BetterWorkspaceCore

struct MacWorkspaceSetupTip: Tip {
    var title: Text { Text("Choose how your workspace is organized") }
    var message: Text? { Text("Choose a root folder, preview optional starter folders, or keep your own structure.") }
    var options: [TipOption] { MaxDisplayCount(1) }
}

private struct MacCustomFoldersTip: Tip {
    var title: Text { Text("Your own folders belong here") }
    var message: Text? { Text("Folders directly inside the root appear in the sidebar. Right-click one and choose Area Settings to customize its layout, icon, queues or visibility.") }
    var options: [TipOption] { MaxDisplayCount(1) }
}

/// A dedicated review screen, not an automatic workspace mutation or root switch.
struct WorkspaceSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var root: URL
    @State private var plan: WorkspaceStarterPlan?
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var message: String?
    @State private var problem: String?

    init(root: URL) { _root = State(initialValue: root) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Workspace Setup").font(.title2.bold())
                Spacer()
                Button("Done") {
                    TestIsolation.defaults.set(true, forKey: "macWorkspaceSetupCompleted")
                    MacWorkspaceSetupTip().invalidate(reason: .actionPerformed)
                    dismiss()
                }.accessibilityIdentifier("workspaceSetup.done").disabled(busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("1. Choose your Workspace root") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Better Workspace discovers folders immediately inside this directory. Your files stay yours.")
                            Text(root.path).font(.caption.monospaced()).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(root.path)
                            HStack {
                                Button("Choose Folder…", action: chooseRoot).accessibilityIdentifier("workspaceSetup.chooseRoot")
                                if root.canonicalPath != model.workspace.root.canonicalPath {
                                    Button("Use on Next Launch") { saveRoot() }
                                        .accessibilityIdentifier("workspaceSetup.useRoot").disabled(plan == nil)
                                }
                            }
                            if root.canonicalPath != model.workspace.root.canonicalPath {
                                Text("The open workspace stays active until you quit and reopen Better Workspace. Choosing another root does not move or merge files.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("2. Optional starter folders") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Keep your own structure, or select only the missing folders you want. Existing folders and their contents are preserved.")
                            if let plan {
                                ForEach(plan.entries) { entry in
                                    HStack(alignment: .top) {
                                        if entry.status == .create {
                                            Toggle(entry.category.name, isOn: Binding(get: { selected.contains(entry.id) }, set: { value in
                                                if value { selected.insert(entry.id) } else { selected.remove(entry.id) }
                                            })).toggleStyle(.checkbox)
                                                .accessibilityIdentifier("workspaceSetup.folder." + entry.id)
                                                .frame(width: 150, alignment: .leading)
                                        } else {
                                            Label(entry.category.name, systemImage: entry.status == .reuse ? "checkmark.circle" : "exclamationmark.triangle")
                                                .frame(width: 150, alignment: .leading)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.explanation).font(.caption).foregroundStyle(entry.status == .blocked ? Color.orange : .secondary)
                                            Text(entry.category.purpose).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } else if busy { ProgressView() }
                            Button("Refresh Preview") { Task { await loadPreview() } }
                                .accessibilityIdentifier("workspaceSetup.refresh").disabled(busy)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    TipView(MacCustomFoldersTip())
                    GroupBox("3. Customize and connect when ready") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Projects hold existing files. Ideas capture possibilities; tasks track actions; features and milestones group plans and outcomes. Goals describe direction; notes keep context, and folders organize related material. Work queues and folder layouts can be customized in Area Settings.")
                            Text("Create any ordinary folder in Finder; it appears after refresh. Below an area, a folder beginning with _ groups files on disk while its children appear directly in that area's listing. At the root, an ordinary _ folder is still an area. Hidden and protected metadata folders remain excluded.")
                                .accessibilityIdentifier("workspaceSetup.folderGuidance")
                            Text("iPhone and iPad work independently. Open Workspace → Devices & recovery on each device with the same iCloud account, then review the initial merge. Review Mac content separately to include indexed files without downloading full development directories.")
                            Button("Open Workspace") { model.selection = .unified; dismiss() }
                                .accessibilityIdentifier("workspaceSetup.openWorkspace")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.callout)
            }.disabled(busy)
            if let message { Text(message).font(.caption).foregroundStyle(.green).accessibilityIdentifier("workspaceSetup.result") }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("workspaceSetup.error") }
            HStack {
                Text("Only checked, missing folders will be created.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Create \(selected.count) Selected \(selected.count == 1 ? "Folder" : "Folders")") { createSelected() }
                    .accessibilityIdentifier("workspaceSetup.create")
                    .disabled(plan == nil || selected.isEmpty || busy)
            }
        }
        .padding(20).frame(width: 560, height: 440)
        .interactiveDismissDisabled(busy)
        .task { await loadPreview(selectDefaults: true) }
    }

    @MainActor private func loadPreview(selectDefaults: Bool = false) async {
        let previousSelection = selected
        busy = true; problem = nil; plan = nil; selected = []
        let chosen = root
        let result = await Task.detached(priority: .userInitiated) { Result { try WorkspaceStarterPlan.preview(root: chosen) } }.value
        switch result {
        case .success(let value):
            plan = value
            let available = Set(value.entries.filter { $0.status == .create }.map(\.id))
            selected = selectDefaults ? available.intersection(["Projects", "Ideas", "To Do"]) : available.intersection(previousSelection)
        case .failure(let error): problem = error.localizedDescription
        }
        busy = false
    }

    @MainActor private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = root; panel.prompt = "Preview Workspace"
        if panel.runModal() == .OK, let url = panel.url {
            root = url; message = nil; plan = nil; selected = []; busy = true
            Task { await loadPreview(selectDefaults: true) }
        }
    }

    @MainActor private func saveRoot() {
        guard let plan else { return }
        Task {
            busy = true
            let result = await Task.detached { Result { try WorkspaceStarterPlan.preview(root: plan.root) } }.value
            if case .success(let fresh) = result, fresh.rootIdentity == plan.rootIdentity {
                TestIsolation.defaults.set(plan.root.canonicalPath, forKey: WorkspaceLocation.defaultsWorkspaceRootKey)
                message = "Workspace folder saved for the next launch. Existing files and synchronization state were retained."
            } else { problem = "The selected folder changed. Refresh its preview before choosing it." }
            busy = false
        }
    }

    @MainActor private func createSelected() {
        guard let plan, !busy else { return }
        let selection = selected
        busy = true; problem = nil; message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try plan.apply(selected: selection) } }.value
            switch result {
            case .success(let outcome):
                message = "Created \(outcome.created.count) folders. Existing files and folders were preserved."
                await loadPreview()
                problem = outcome.issue
                if plan.root.canonicalPath == model.workspace.root.canonicalPath { await model.refreshFolders() }
            case .failure(let error): problem = error.localizedDescription
            }
            busy = false
        }
    }
}
