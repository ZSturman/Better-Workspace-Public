import SwiftUI
import BetterWorkspaceCore

/// The one explicit hand-off from a project row/card into a native project tool.
/// Keeping the item snapshot here avoids reading environment state from a departing
/// Table row, which is unsafe during AppKit's removal layout pass.
struct ProjectToolTarget: Identifiable {
    enum Kind: String { case explain, flowReview }
    let kind: Kind
    let item: WorkspaceItem
    var id: String { kind.rawValue + ":" + item.id }
}

struct ProjectToolSheet: View {
    @Environment(AppModel.self) private var model
    let target: ProjectToolTarget

    var body: some View {
        Group {
            switch target.kind {
            case .explain: ExplainProjectView(item: target.item)
            case .flowReview: FlowReviewProjectView(item: target.item)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .environment(model)
    }
}

private struct ExplainProjectView: View {
    @Environment(AppModel.self) private var model
    let item: WorkspaceItem
    @State private var report: ProjectExplanationReport?
    @State private var investigation: ProjectInvestigation?
    @State private var verification: VerificationPlan?
    @State private var question = ""
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView("Analyzing \(item.displayTitle)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.base) {
                        overview(report)
                        if let investigation { investigationView(investigation) }
                        actions(report)
                        questionBox(report)
                    }
                    .padding(Theme.Space.base)
                }
            } else {
                EmptyAreaState(symbol: "exclamationmark.triangle", title: "Couldn’t explain this project",
                               message: "The project may have moved or become unavailable.")
            }
        }
        .task(id: item.url.canonicalPath) { await load() }
        .sheet(item: $verification) { plan in VerificationPlanView(plan: plan) }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Explain").font(.title2.weight(.semibold))
                Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Reveal") { model.revealInFinder(item.url) }
            Button("Done") { model.projectToolTarget = nil }
        }
        .padding(Theme.Space.base)
    }

    private func overview(_ report: ProjectExplanationReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Overview").font(.headline)
            Text("\(report.sourceFileCount) source files" + (report.languages.isEmpty ? "" : " · \(report.languages.joined(separator: ", "))"))
                .foregroundStyle(.secondary)
            ForEach(report.findings) { finding in FindingView(finding: finding) }
        }
    }

    private func investigationView(_ investigation: ProjectInvestigation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text(investigation.title).font(.headline)
            Text(investigation.question).font(.callout).foregroundStyle(.secondary)
            ForEach(investigation.findings) { FindingView(finding: $0) }
            if investigation.filesExamined.isEmpty == false {
                DisclosureGroup("Files examined") {
                    ForEach(investigation.filesExamined, id: \.self) { path in
                        Text(path).font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
        .padding(Theme.Space.base)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func actions(_ report: ProjectExplanationReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Investigate next").font(.headline)
            ProjectToolFlowLayout(spacing: Theme.Space.tight) {
                ForEach(report.actions) { action in
                    Button(action.title) {
                        if action.id == "verification" { Task { verification = await ProjectExplanationService.shared.verificationPlan(for: report) } }
                        else { Task { investigation = await ProjectExplanationService.shared.investigate(action, report: report) } }
                    }
                    .help(action.description)
                }
            }
        }
    }

    private func questionBox(_ report: ProjectExplanationReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Ask about this project").font(.headline)
            HStack {
                TextField("For example: Did I implement offline sync?", text: $question)
                Button("Ask") {
                    let asked = question; question = ""
                    Task { investigation = await ProjectExplanationService.shared.answer(asked, in: report) }
                }
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Answers remain evidence-based. Local AI can be configured later; it is never contacted automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @MainActor private func load() async {
        isLoading = true
        report = await ProjectExplanationService.shared.analyze(at: item.url)
        isLoading = false
    }
}

private struct FindingView: View {
    let finding: ProjectToolFinding
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(finding.title).font(.subheadline.weight(.medium)); Text(finding.confidence.uppercased()).font(.caption2).foregroundStyle(.secondary) }
            Text(finding.statement).font(.callout)
            if finding.evidence.isEmpty == false {
                DisclosureGroup("Evidence") {
                    ForEach(finding.evidence) { evidence in
                        Text(evidence.path.map { "\($0): " } ?? "" + evidence.detail)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct VerificationPlanView: View {
    let plan: VerificationPlan
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Text("Run Verification").font(.title2.weight(.semibold))
            Text(plan.safetyNote).foregroundStyle(.secondary)
            if plan.commands.isEmpty { Text("No direct allowlisted checks were detected.").foregroundStyle(.secondary) }
            ForEach(plan.commands) { command in
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.name).fontWeight(.medium)
                    Text(command.command.joined(separator: " ")).font(.system(.caption, design: .monospaced))
                    Text(command.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack { Button("Done") { dismiss() }; Spacer(); Button("Run Allowlisted Checks") { confirmed = true }.buttonStyle(.borderedProminent) }
        }
        .padding(24).frame(minWidth: 560, minHeight: 360)
        .alert("Verification execution is not yet available", isPresented: $confirmed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The plan is shown safely, but this build does not execute project commands from Better Workspace.")
        }
    }
}

private struct FlowReviewProjectView: View {
    @Environment(AppModel.self) private var model
    let item: WorkspaceItem
    @State private var analysis: FlowReviewAnalysis?
    @State private var changes: [FlowReviewChange] = []
    @State private var selectedScheme = ""
    @State private var showConfirmation = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: "play.rectangle.on.rectangle").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) { Text("Flow Review").font(.title2.weight(.semibold)); Text(item.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(); Button("Done") { model.projectToolTarget = nil }
            }.padding(Theme.Space.base)
            Divider()
            if let analysis { content(analysis) } else { ProgressView("Inspecting Xcode project…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: item.url.canonicalPath) { await load() }
        .confirmationDialog("Apply Flow Review changes?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Apply Changes") { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Only the listed project-local Flow Review files will be created. Existing source and Xcode project wiring are not changed by this initial native integration.") }
    }

    private func content(_ analysis: FlowReviewAnalysis) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                if let reason = analysis.blockingReason { EmptyAreaState(symbol: "xcode", title: "Flow Review unavailable", message: reason) }
                else {
                    Text(analysis.readyToRun ? "Ready to review \(analysis.flowFiles.count) flow(s)." : "Flow Review needs configuration or a flow.")
                        .foregroundStyle(.secondary)
                    if analysis.schemes.isEmpty == false { Picker("Scheme", selection: $selectedScheme) { ForEach(analysis.schemes, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 380) }
                    if analysis.flowFiles.isEmpty == false { section("Flows") { ForEach(analysis.flowFiles, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) } } }
                    if changes.isEmpty == false { section("Change preview") { ForEach(changes) { change in VStack(alignment: .leading) { Text(change.path).font(.system(.callout, design: .monospaced)); Text(change.summary).font(.caption).foregroundStyle(.secondary) } } } }
                    HStack {
                        Button(analysis.configured ? "Repair Configuration" : "Prepare Configuration") { Task { changes = await FlowReviewService.shared.configurationPlan(for: analysis, scheme: selectedScheme.nonEmpty) } }.buttonStyle(.borderedProminent)
                        if changes.isEmpty == false { Button("Apply Previewed Changes") { showConfirmation = true } }
                        Button("Reveal Runs") { model.revealInFinder(item.url.appendingPathComponent(".flow-review/runs")) }
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Text("Local AI drafting and simulator execution are opt-in follow-up features; no network request or simulator action happens while this view is opened.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(Theme.Space.base)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: Theme.Space.snug) { Text(title).font(.headline); content() } }
    @MainActor private func load() async { let value = await FlowReviewService.shared.analyze(at: item.url); analysis = value; selectedScheme = value.schemes.first ?? "" }
    @MainActor private func apply() async {
        guard let analysis else { return }
        do { try await FlowReviewService.shared.apply(configurationPlan: changes, for: analysis, scheme: selectedScheme.nonEmpty); message = "Created the previewed Flow Review files."; await load() }
        catch { message = error.localizedDescription }
    }
}

/// A tiny wrapping layout for action buttons; avoids squeezing the Review-card title
/// at the 820pt minimum window size.
private struct ProjectToolFlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500; var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews { let size = view.sizeThatFits(.unspecified); if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }; x += size.width + spacing; row = max(row, size.height) }
        return .init(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews { let size = view.sizeThatFits(.unspecified); if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }; view.place(at: .init(x: x, y: y), proposal: .unspecified); x += size.width + spacing; row = max(row, size.height) }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
