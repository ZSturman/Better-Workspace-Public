import SwiftUI
import AppKit
import TipKit
import BetterWorkspaceCore

private struct WorkspaceApplicationInfo: Sendable {
    let url: URL
    let identity: FileIdentity
    let name: String
    let bundleID: String
    let version: String
    let minimumSystem: String?
    static func read(_ item: WorkspaceRootItem) throws -> Self {
        guard FileIdentityResolver.identity(of: item.url) == item.identity,
              let target = WorkspaceRootDiscovery.applicationURL(for: item.url),
              let identity = FileIdentityResolver.identity(of: target), let bundle = Bundle(url: target),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let identifier = bundle.bundleIdentifier else {
            throw WorkspaceReplicaError.invalid("This application is unavailable or its bundle is incomplete. Locate it in Finder and refresh the workspace.")
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? item.title
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Not provided"
        return .init(url: target, identity: identity, name: name, bundleID: identifier, version: version,
                     minimumSystem: bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String)
    }
}

struct WorkspaceApplicationDetail: View {
    let item: WorkspaceRootItem
    @State private var info: WorkspaceApplicationInfo?
    @State private var error: String?
    @State private var opening = false
    @State private var shortcut = ""
    private var shortcutKey: String { "workspace.applicationShortcut." + (info?.bundleID ?? item.id) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: info?.url.path ?? item.url.path))
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info?.name ?? item.title).font(.title2.bold()).accessibilityIdentifier("rootApp.name")
                        if let info { Text("Version " + info.version).foregroundStyle(.secondary) }
                    }
                }
                HStack {
                    Button("Open Application") { openApplication() }
                        .buttonStyle(.borderedProminent).disabled(info == nil || opening)
                        .accessibilityIdentifier("rootApp.open")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                }
                if let info {
                    LabeledContent("Identifier", value: info.bundleID)
                    if let minimum = info.minimumSystem { LabeledContent("Requires macOS", value: minimum) }
                    Text(info.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Divider()
                    Text("Actions").font(.headline)
                    Text("Open the app to use its full interface. If it offers actions in Shortcuts, you can explore them there and choose a shortcut to run here.")
                    Button("Explore in Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
                        .accessibilityIdentifier("rootApp.shortcuts")
                    TextField("Shortcut name", text: $shortcut, prompt: Text("Name of a shortcut you've chosen"))
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("rootApp.shortcutName")
                    Button("Run Shortcut") {
                        guard let url = WorkspaceWebPolicy.shortcut(named: shortcut) else { return }
                        TestIsolation.defaults.set(shortcut, forKey: shortcutKey)
                        if !NSWorkspace.shared.open(url) { error = "Shortcuts could not be opened. Open it from Applications and try again." }
                    }.disabled(WorkspaceWebPolicy.shortcut(named: shortcut) == nil)
                        .accessibilityIdentifier("rootApp.runShortcut")
                    Text("Runs the named shortcut through Shortcuts, with its normal permissions. No files or clipboard content are supplied.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("rootApp.error") }
            }.padding(24).frame(maxWidth: 680, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item) { @MainActor in
            info = nil; error = nil
            let result = await Task.detached(priority: .userInitiated) { Result { try WorkspaceApplicationInfo.read(item) } }.value
            switch result {
            case .success(let value): info = value; shortcut = TestIsolation.defaults.string(forKey: shortcutKey) ?? ""
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    @MainActor private func openApplication() {
        guard let info else { return }
        guard FileIdentityResolver.identity(of: item.url) == item.identity,
              WorkspaceRootDiscovery.applicationURL(for: item.url) == info.url,
              FileIdentityResolver.identity(of: info.url) == info.identity else {
            error = "This application changed. Refresh the workspace before opening it."; return
        }
        opening = true; error = nil
        NSWorkspace.shared.openApplication(at: info.url, configuration: .init()) { _, failure in
            Task { @MainActor in opening = false; if let failure { error = failure.localizedDescription } }
        }
    }
}

struct WorkspaceRootFileDetail: View {
    let item: WorkspaceRootItem
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(item.title, systemImage: item.symbol).font(.title2)
            Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let warning = item.warning { Text(warning).foregroundStyle(.orange) }
            HStack {
                Button("Open File") { NSWorkspace.shared.open(item.url) }.accessibilityIdentifier("rootFile.open")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
            Text("Use the file's default application to view and edit its contents.").foregroundStyle(.secondary)
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct WorkspaceRootItemsTip: Tip {
    var title: Text { Text("Apps and links have their own place") }
    var message: Text? { Text("Root applications open with app details and Shortcuts actions. Webpage shortcuts and linked text notes open inside the workspace.") }
    var options: [TipOption] { MaxDisplayCount(1) }
}
