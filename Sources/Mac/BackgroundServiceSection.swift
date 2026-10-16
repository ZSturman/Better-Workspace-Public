import SwiftUI
import BetterWorkspaceCore

/// The background service in Settings: whether it is running, who launches it, and the
/// one action that matters — adopting it from Workspace Watcher, or repairing it.
struct BackgroundServiceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Advanced workspace services notice work sessions, draft the work log, "
                 + "store idea scores and resurface ideas while you work. Starting them "
                 + "enables a login item. My Workspace works independently; browsing folders "
                 + "also remains available without these services. Idea metadata and observed "
                 + "sessions require the service.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status = model.serviceAgentStatus {
                statusRows(status)
            } else {
                ProgressView().controlSize(.small)
            }

            HStack(spacing: Theme.Space.tight) {
                Button(installTitle) {
                    Task { @MainActor in await model.installBackgroundService() }
                }
                .disabled(model.serviceBusy || model.serviceAgentStatus?.bundledServicePresent == false)
                .help("Runs the service under Better Workspace's own login item and retires "
                      + "Workspace Watcher's agents. Its data stays where it is.")
                if model.serviceBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Show Logs") { model.revealInFinder(BackgroundServiceAgent().logDirectory) }
                    .help("The service's logs and database, in ~/Workspace/Logs/workspace-watcher.")
            }

            Divider()
            ServiceNotionSection()
        }
        .task { @MainActor in await model.refreshServiceAgentStatus() }
    }

    private var installTitle: String {
        guard let status = model.serviceAgentStatus else { return "Start Background Service" }
        if status.loaded { return status.codeMatchesBundle == false ? "Update Background Service" : "Restart Background Service" }
        if status.legacyDaemonLoaded { return "Adopt from Workspace Watcher" }
        return "Start Background Service"
    }

    @ViewBuilder
    private func statusRows(_ status: BackgroundServiceAgent.Status) -> some View {
        let running = status.loaded && status.pid != nil
        LabeledContent("Status") {
            Label(running ? "Running" : (status.legacyDaemonLoaded ? "Running under Workspace Watcher" : "Not running"),
                  systemImage: running ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(running ? .green : .orange)
                .font(.caption)
        }
        LabeledContent("Launched by") { Text(status.owner).font(.caption) }
        if status.legacyMenuBarLoaded {
            Text("Workspace Watcher's separate menu bar is still running. Adopting retires it; "
                 + "Better Workspace's own menu bar shows the current session and suggestions.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if status.codeMatchesBundle == false {
            Label("This version of Better Workspace includes a different background service than the one running. "
                  + "Update it to use idea classification, potential-project details and other new features. "
                  + "Its data and configuration are kept.", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("service.updateAvailable")
        }
        if status.runsFromLegacyCheckout {
            Text("Still running from the Workspace Watcher checkout. Restarting installs it into "
                 + "Better Workspace's own folder, so that checkout is no longer needed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the background service sees right now, in the menu bar: the session in
/// progress and the ideas it is resurfacing for it. This is what Workspace Watcher's
/// separate menu bar process used to show.
struct ServiceActivityMenuSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let live = model.liveSession {
            Divider()
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: "record.circle").font(.system(size: 10)).foregroundStyle(.green)
                Text(live.projectName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer()
                Text(Format.duration(seconds: live.elapsedSeconds))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Working on \(live.projectName)")
        }
        let suggestions = Array(model.resurfacedSuggestions.prefix(3))
        if suggestions.isEmpty == false {
            Divider()
            Text("Resurfaced").font(.system(size: 11, weight: .semibold))
            ForEach(suggestions) { suggestion in
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: "lightbulb").font(.system(size: 10)).foregroundStyle(.yellow)
                    Text(suggestion.title).font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Menu {
                        if let url = model.ideaURL(for: suggestion) {
                            Button("Open") {
                                model.open(url)
                                Task { @MainActor in await model.act(on: suggestion, .open) }
                            }
                        }
                        Button("Not Related to This Project") {
                            Task { @MainActor in await model.act(on: suggestion, .notRelated) }
                        }
                        Button("Dismiss") {
                            Task { @MainActor in await model.act(on: suggestion, .dismiss) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
}

/// The service's optional Notion integration, as it is actually configured: which
/// databases, what is mirrored, and how it last went — and the one switch a person
/// changes day to day, mirroring ideas.
struct ServiceNotionSection: View {
    @State private var status: ServiceNotionStatus?
    @State private var unreachable = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Notion (optional)").font(.system(size: 12, weight: .semibold))
            if let status {
                rows(status)
            } else if unreachable {
                Text("The background service isn't running, so its Notion settings can't be read.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        status = await BackgroundServiceClient.shared.notionStatus()
        unreachable = status == nil
    }

    @ViewBuilder
    private func rows(_ status: ServiceNotionStatus) -> some View {
        Text("Your files and this app's records are the source of truth. Notion only mirrors "
             + "what is switched on below.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        LabeledContent("Token") {
            Text(status.tokenPresent ? "Present (in the service's .env)" : "None").font(.caption)
        }
        LabeledContent("Projects database") {
            database(status.projectsDatabaseID, detail: status.enabled ? "read, to name work-log projects" : "not read",
                     health: status.projectsCacheHealth)
        }
        LabeledContent("Ideas database") {
            database(status.ideasDatabaseID, detail: status.ideasSyncEnabled ? "ideas mirrored here" : "not mirrored",
                     health: status.ideasSyncEnabled ? status.ideasSyncHealth : nil)
        }
        LabeledContent("Work log database") {
            database(status.workLogDatabaseID,
                     detail: status.workLogSyncEnabled ? "work log written here" : "not written (config.toml switch)",
                     health: nil)
        }
        Toggle("Mirror ideas to the Notion Ideas database", isOn: Binding(
            get: { status.ideasSyncEnabled },
            set: { enabled in
                Task { @MainActor in
                    saving = true
                    _ = await BackgroundServiceClient.shared.setIdeasNotionSync(enabled)
                    await load()
                    saving = false
                }
            }
        ))
        .disabled(saving || status.enabled == false)
        .accessibilityIdentifier("service.notion.mirrorIdeas")
        .font(.caption)
        .help("Off stops writing ideas to Notion and pulling new ones from it. Local ideas, their "
              + "metadata and resurfacing are unaffected. Nothing in Notion is deleted.")
        if let paused = status.ideasSyncPausedUntil {
            Text("The Ideas database could not be found; the service will try again \(Format.relativeDate(paused)).")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func database(_ id: String?, detail: String, health: ServiceNotionStatus.Health?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(id.map { String($0.prefix(8)) + "…" } ?? "none")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .help(id ?? "")
            Text(detail).font(.caption2).foregroundStyle(.secondary)
            if let health, health.state != "ok" {
                Text(health.state == "database_missing" ? "Database missing" : (health.error ?? health.state))
                    .font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }
}
