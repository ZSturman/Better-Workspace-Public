import SwiftUI
import AppKit
import QuickLook
import BetterWorkspaceCore

/// One due item from the To folders, decided the way Inbox Review decides it: the
/// folder names the primary action, "Deal with later" snoozes to tomorrow, the rest is
/// under More. Every move is journaled and the last one can be undone here, so only
/// Trash asks first.
struct OverviewInboxView: View {
    @Bindable var controller: OverviewInboxController
    @State private var quickLook: URL?
    @State private var confirmingTrash = false
    @AppStorage("overview.reviewExpanded", store: TestIsolation.defaults) private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    Text("Inbox Review").fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text(controller.verified ? "\(controller.dueCount) due" : "Checking…")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse review" : "Expand review")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("overview.toReview.disclosure")
            if let item = controller.item {
                let actions = WorkspaceInboxReview.ReviewActions(category: item.category)
                Text("\(item.category) · \(actions.purpose)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    .accessibilityIdentifier("overview.toReview.title")
                if expanded, let url = controller.selectedURL {
                    OverviewReviewPreview(controller: controller, item: item, url: url)
                        .id(item.id)
                } else if !item.preview.isEmpty {
                    Text(item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Wraps at narrow widths; ViewThatFits widened the column's minimum.
                FlowLayout(spacing: Theme.Space.tight) { buttons(item, actions: actions) }
                    .disabled(controller.busy || !controller.verified)
            } else {
                Text(controller.loading && controller.checkedAt == nil ? "Checking To folders…"
                     : controller.checkedAt == nil ? "The review queue is not available yet."
                     : "Nothing is due. Snoozed and protected files stay where they are.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if controller.undoAvailable || controller.message != nil {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                    if let message = controller.message {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if controller.undoAvailable {
                        Button("Undo last review") { Task { await controller.undo() } }
                            .controlSize(.small).disabled(controller.busy)
                            .accessibilityIdentifier("overview.toReview.undo")
                    }
                }
            }
        }
        .padding(Theme.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.toReview")
        .quickLookPreview($quickLook)
        .confirmationDialog("Move “\(controller.item?.title ?? "this item")” to the Trash?", isPresented: $confirmingTrash,
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await controller.act(.trash) } }
        } message: { Text("It stays recoverable from the Trash, and Undo here puts it back while the Trash copy is unchanged.") }
        .task {
            while !Task.isCancelled {
                await controller.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder private func buttons(_ item: OverviewInboxItem, actions: WorkspaceInboxReview.ReviewActions) -> some View {
        primary(item, actions: actions)
        secondary(item, actions: actions)
    }

    @ViewBuilder private func primary(_ item: OverviewInboxItem, actions: WorkspaceInboxReview.ReviewActions) -> some View {
        if actions.primary == .move {
            Button("Move to…") { chooseDestination() }.buttonStyle(.borderedProminent)
                .accessibilityIdentifier("overview.toReview.primary")
        } else {
            Button(actions.title) { Task { await controller.act(.done) } }.buttonStyle(.borderedProminent)
                .accessibilityIdentifier("overview.toReview.primary")
        }
        Button("Deal with later") { Task { await controller.snooze(days: 1) } }
            .accessibilityIdentifier("overview.toReview.later")
    }

    @ViewBuilder private func secondary(_ item: OverviewInboxItem, actions: WorkspaceInboxReview.ReviewActions) -> some View {
        Button("Preview") { quickLook = controller.selectedURL }
        Button("Open") { controller.open() }
        if actions.showsDelete {
            Button("Delete…", role: .destructive) { confirmingTrash = true }
        }
        Menu("More") {
            Button("Another item") { Task { await controller.refresh(force: true, advance: true) } }
            Button("Refresh") { Task { await controller.refresh(force: true) } }
            Divider()
            Menu("Priority \(item.priority ?? 3)") {
                ForEach(1...5, id: \.self) { value in Button("\(value) · \(value == 5 ? "Highest" : value == 1 ? "Lowest" : "Priority")") { Task { await controller.setPriority(value) } } }
            }
            Button("Snooze three days") { Task { await controller.snooze(days: 3) } }
            Button("Snooze one month") { Task { await controller.snooze(days: 30) } }
            Button("Snooze one week") { Task { await controller.snooze(days: 7) } }
            Divider()
            Button("Archive") { Task { await controller.act(.archive) } }
            Button(actions.retireTitle) { Task { await controller.act(.retire) } }
            Divider()
            Button("Reveal in Finder") {
                if let url = controller.selectedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        .fixedSize()
        .accessibilityIdentifier("overview.toReview.more")
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = controller.workspace
        panel.prompt = "Move Here"
        panel.message = "Choose where “\(controller.item?.title ?? "this item")” belongs."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await controller.act(.move, destination: url) }
        }
    }
}
