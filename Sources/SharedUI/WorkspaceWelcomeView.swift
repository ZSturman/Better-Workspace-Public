import SwiftUI
import BetterWorkspaceCore

/// One vocabulary across platforms; capabilities, rather than product internals,
/// explain which experience a person is choosing.
struct WorkspaceWelcomeView: View {
    enum Platform { case mobile, storeMac, advancedMac }
    let platform: Platform
    let startPersonal: () -> Void
    let connect: (() -> Void)?
    let exploreSample: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 42)).foregroundStyle(.tint)
                Text("Make room for your next step.").font(.largeTitle.bold())
                Text("Keep projects, tasks, ideas and documents together. Start small, choose what matters today, and keep the details close.")
                    .font(.title3).foregroundStyle(.secondary)
                if platform == .storeMac { capability("Start here, on this device", symbol: "checkmark.circle", detail: "Create a project, write a note or save an idea. Your personal workspace works offline and needs no Mac or background service.") }
                if platform == .mobile {
                    capability("Your Workspace, wherever you are", symbol: "desktopcomputer", detail: "The Workspace lives on your Mac. Open Better Workspace on the Mac and enable mobile access using the same Apple account. Browse, score and plan from your phone; saves wait safely until your Mac is available.")
                } else if platform == .advancedMac {
                    capability("Keep your existing folders", symbol: "folder", detail: "The advanced Mac workspace browses files you choose. Monitoring, observed sessions, idea metadata and agents are additional capabilities, with setup explained in Settings.")
                } else {
                    capability("More ways to work on Mac", symbol: "desktopcomputer", detail: "This app keeps your personal projects and notes together. The separate advanced Mac download adds folder browsing, monitoring and automation. You can use this workspace without installing it.")
                }
                capability("Know where your information lives", symbol: "lock.shield", detail: WorkspaceNotebookPersistence.isCloudSyncEnabled ? "Personal items are saved on this device and sync through your private iCloud account when available. You can work offline; transfers may take a few minutes. Connected workspace files stay in your folders. No advertising or cross-app tracking." : "Personal items live in private app storage on this device. Connected workspace files stay in your folders; its index uses private iCloud and captures use iCloud Drive. No advertising or cross-app tracking.")
                Button(action: startPersonal) { Label("Open Workspace", systemImage: "plus.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("welcome.startPersonal")
                if let connect, platform != .advancedMac {
                    Button("Open Workspace", action: connect)
                        .accessibilityIdentifier("welcome.connect")
                }
                if let exploreSample {
                    Button(platform == .storeMac ? "Try a private sample" : "Explore a read-only sample", action: exploreSample)
                        .accessibilityIdentifier("welcome.sample")
                }
                Link("Setup, capabilities & support", destination: URL(string: "https://zacharysturman.com/better-workspace/support")!)
                    .font(.footnote)
            }
            .padding(28).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("workspace.welcome")
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 660, minHeight: 580)
        #endif
    }

    private func capability(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
