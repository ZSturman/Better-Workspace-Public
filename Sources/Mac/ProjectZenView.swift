import SwiftUI
import BetterWorkspaceCore

struct ProjectZenDraft: Codable {
    var index = 0
    var answers: [String: String] = [:]
}

enum ProjectZenEntry: String, CaseIterable, Identifiable {
    case details, planning, media, scoring
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ProjectZenQuestion: Identifiable {
    let id: String
    let prompt: String
    let hint: String
}

/// Mouse-only review. Freeform writing belongs in Details, never in Zen.
struct ProjectZenView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: WorkspaceItem?
    let project: ProjectGraphRecord?
    @State private var entry = ProjectZenEntry.details
    @State private var draft = ProjectZenDraft()
    @State private var error: String?
    @State private var applying = false
    @State private var draftPersistence: Task<Void, Never>?
    @State private var draftsByKey: [String: ProjectZenDraft] = [:]

    // Keep legacy text interviews intact, but never apply them through a choice flow.
    private var key: String { "zen.choices.\(project?.id ?? item?.id ?? "project").\(entry.rawValue)" }
    private var currentProject: ProjectGraphRecord? { project.map { original in model.graphRecords.first { $0.id == original.id } ?? original } }
    private var questions: [ProjectZenQuestion] {
        switch entry {
        case .details: return [
            .init(id: "domain", prompt: "Which domain does this project belong to?", hint: "Choose a domain. Descriptions can be edited in Details."),
            .init(id: "Type", prompt: "What kind of project is this?", hint: "Choose its category or type."),
            .init(id: "Status", prompt: "What is its current status?", hint: "Choose where the project stands today."),
            .init(id: "Phase", prompt: "Which phase are you working through?", hint: "Choose the phase that fits your current work.")]
        case .planning: return [
            .init(id: "task", prompt: "Which task should you focus on?", hint: "Choose existing work. Add or describe tasks in the Tasks view."),
            .init(id: "stage", prompt: "When will you work on it?", hint: "Now and Next make actionable work eligible for your next action.")]
        case .media: return ["thumbnail", "poster", "hero", "banner", "icon"].map {
            .init(id: $0, prompt: "Which asset should be the \($0)?", hint: "Choose an existing asset. Add files and edit collections in Media.")
        }
        case .scoring: return MetricDefinition.all.map {
            .init(id: $0.id, prompt: $0.question, hint: "Choose a number from 1 to 5, or skip if you do not know yet.")
        }
        }
    }
    private var atReview: Bool { draft.index >= questions.count }
    private var planningTasks: [WorkItem] { item.map { model.projectWorkItems(for: $0).filter { $0.kind == .task && $0.isOpen } } ?? [] }
    private var graphTasks: [ProjectGraphRecord] {
        guard let project = currentProject else { return [] }
        let localIDs = Set(planningTasks.compactMap { $0.importedNotionPageID.map(ProjectGraph.normalizedID) })
        return model.graphRelated(to: project).filter { record in
            record.kind == .tasks && !localIDs.contains(ProjectGraph.normalizedID(record.pageID ?? record.id)) &&
                !model.graphRecordIsCompleted(record)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Zen mode").font(.title2.weight(.semibold))
                Spacer()
                Text(item?.displayTitle ?? project?.title ?? "Project").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Picker("Review", selection: $entry) { ForEach(ProjectZenEntry.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            if atReview {
                Text("Review your changes").font(.title3.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(questions.filter { draft.answers[$0.id] != nil }) { question in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(question.prompt).font(.headline)
                                Text(answerLabel(question.id, value: draft.answers[question.id] ?? ""))
                            }
                        }
                        if draft.answers.isEmpty { Text("No changes selected.").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Apply saves your choices locally. Send to Notion remains a separate reviewed action.").font(.caption).foregroundStyle(.secondary)
            } else {
                let question = questions[draft.index]
                Text("\(draft.index + 1) of \(questions.count)").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(draft.index), total: Double(questions.count))
                Text(question.prompt).font(.title2.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(question.hint).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        let options = choices(for: question.id)
                        if entry == .scoring {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(options, id: \.self) { value in ratingButton(question.id, value: value) }
                            }
                            if let metric = MetricDefinition.all.first(where: { $0.id == question.id }),
                               let value = draft.answers[question.id], let anchor = metric.anchors.first(where: { String($0.rating) == value }) {
                                Text(anchor.description).font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                            } else { Text("Select a rating to see its explanation.").font(.caption).foregroundStyle(.secondary).padding(.top, 6) }
                        } else {
                            ForEach(options, id: \.self) { value in choiceButton(question.id, value: value) }
                        }
                        if options.isEmpty {
                            Text("No choices are available yet. You can skip this step and add options in the project’s \(entry == .media ? "Media" : entry == .planning ? "Tasks" : "Details") view.")
                                .foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Save & Exit") { persist(); Task { @MainActor in await draftPersistence?.value; if error == nil { dismiss() } } }.disabled(applying)
                Spacer()
                Button("Back") { draft.index = max(0, draft.index - 1); persist() }.disabled(draft.index == 0 || applying)
                if atReview {
                    Button("Apply approved answers") { Task { await apply() } }.buttonStyle(.borderedProminent).disabled(applying || draft.answers.isEmpty)
                } else {
                    Button("Skip") {
                        draft.answers.removeValue(forKey: questions[draft.index].id)
                        if entry == .planning && questions[draft.index].id == "task" { draft.answers.removeValue(forKey: "stage"); draft.index = questions.count; persist() }
                        else { if entry == .planning { draft.answers.removeValue(forKey: "task") }; advance() }
                    }
                    Button(draft.index == questions.count - 1 ? "Review" : "Next") { advance() }.buttonStyle(.borderedProminent)
                        .disabled(draft.answers[questions[draft.index].id] == nil)
                }
            }
        }.padding(24).frame(width: 570, height: 440)
        .accessibilityIdentifier("projects.zen")
        .onAppear { restore() }.onChange(of: entry) { _, _ in restore() }
        .interactiveDismissDisabled(applying)
    }

    private func ratingButton(_ id: String, value: String) -> some View {
        let selected = draft.answers[id] == value
        let label = MetricDefinition.all.first { $0.id == id }?.anchors.first { String($0.rating) == value }?.label ?? value
        return Button { draft.answers[id] = value; persist() } label: {
            VStack(spacing: 5) {
                Text(value).font(.title2.weight(.semibold).monospacedDigit())
                Text(label).font(.caption).lineLimit(2).frame(height: 30, alignment: .top)
            }.padding(10).frame(maxWidth: .infinity)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }.buttonStyle(.plain).accessibilityIdentifier("projects.zen.choice.\(id).\(value)")
            .accessibilityLabel("\(value) — \(label)")
    }

    private func choiceButton(_ id: String, value: String) -> some View {
        let selected = draft.answers[id] == value
        return Button {
            draft.answers[id] = value
            if entry == .planning && id == "task" { draft.answers.removeValue(forKey: "stage") }
            persist()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(answerLabel(id, value: value)).font(.body.weight(.medium))
                    if entry == .scoring, let metric = MetricDefinition.all.first(where: { $0.id == id }),
                       let anchor = metric.anchors.first(where: { String($0.rating) == value }) {
                        Text(anchor.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityIdentifier("projects.zen.choice.\(id).\(value)")
    }

    private func choices(for id: String) -> [String] {
        switch entry {
        case .scoring: return (1...5).map(String.init)
        case .planning:
            if id == "task" { return planningTasks.map(\.id) + graphTasks.map(\.id) }
            if let selected = graphTasks.first(where: { $0.id == draft.answers["task"] }), let source = model.graphSource(for: selected),
               let property = source.property(named: "Work Stage"), source.writable(property.id) {
                let type = property.definition["type"].string ?? "select"
                return property.definition[type]["options"].array.compactMap { $0["name"].string }.filter { ["now", "next", "later"].contains($0.lowercased()) }
            }
            return planningTasks.contains(where: { $0.id == draft.answers["task"] }) ? ["Now", "Next", "Later"] : []
        case .media:
            guard let project = currentProject, let source = model.graphSource(for: project),
                  let property = source.property(named: id), property.definition["type"].string == "relation", source.writable(property.id) else { return [] }
            return model.graphMediaRelated(to: project).filter { $0.kind == .assets && $0.sourceID == property.definition["relation"]["data_source_id"].string }.map { $0.pageID ?? $0.id }
        case .details:
            if let project = currentProject, let source = model.graphSource(for: project) {
                guard let property = source.property(named: id), source.writable(property.id) else { return [] }
                let type = property.definition["type"].string ?? ""
                guard ["select", "status", "multi_select"].contains(type) else { return [] }
                return property.definition[type]["options"].array.compactMap { $0["name"].string }
            }
            let defaults: [String: [String]] = ["domain": ["Apps", "Design", "Writing", "Research", "Personal"], "Type": ["App", "Website", "Tool", "Creative", "Research"], "Status": ["Idea", "Active", "Paused", "Complete", "Archived"], "Phase": ["Discovery", "Design", "Implementation", "Validation", "Maintenance"]]
            let existing = model.projects().compactMap { project -> String? in
                let metadata = model.projectMetadata(for: project)
                switch id { case "domain": return metadata.domain; case "Type": return metadata.projectType; case "Status": return metadata.status; default: return metadata.phase }
            }
            return Array(Set(existing + (defaults[id] ?? []))).filter { !$0.isEmpty }.sorted()
        }
    }

    private func answerLabel(_ id: String, value: String) -> String {
        if entry == .planning && id == "task" { return planningTasks.first { $0.id == value }?.title ?? graphTasks.first { $0.id == value }?.title ?? "Task unavailable" }
        if entry == .media { return model.graphRecords.first { $0.pageID == value || $0.id == value }?.title ?? "Asset unavailable" }
        if entry == .scoring, let metric = MetricDefinition.all.first(where: { $0.id == id }), let anchor = metric.anchors.first(where: { String($0.rating) == value }) { return "\(value) — \(anchor.label)" }
        return value
    }
    private func advance() { draft.index += 1; persist() }
    private func restore() { draft = draftsByKey[key] ?? (try? ProjectGraphStore(database: model.database).read(key, as: ProjectZenDraft.self)) ?? .init(); draft.index = min(max(0, draft.index), questions.count); error = nil }
    private func persist() {
        let key = key, value = draft, database = model.database, previous = draftPersistence
        draftsByKey[key] = value
        // Serialize writes without ever waiting for SQLite on the event-handling thread.
        draftPersistence = Task { @MainActor in
            await previous?.value
            do {
                try await Task.detached(priority: .userInitiated) { try ProjectGraphStore(database: database).write(key, value) }.value
                error = nil
            } catch { self.error = error.localizedDescription; model.lastError = error.localizedDescription }
        }
    }

    @MainActor private func apply() async {
        applying = true; defer { applying = false }
        do {
            for (id, value) in draft.answers {
                guard choices(for: id).contains(value) else { throw NotionProjectSync.SyncError.unsupported("A selected choice is no longer available. Go Back and choose again.") }
            }
            if entry == .planning {
                guard let id = draft.answers["task"], let stage = draft.answers["stage"] else { throw NotionProjectSync.SyncError.unsupported("Choose a task and a stage before applying.") }
                if var work = planningTasks.first(where: { $0.id == id }), let value = WorkItemStage(rawValue: stage.lowercased()) {
                    work.stage = value; _ = try await model.saveWorkItem(work)
                } else if var work = graphTasks.first(where: { $0.id == id }), let source = model.graphSource(for: work) {
                    work.set("Work Stage", value: ProjectJSON(["name": stage]), source: source); work.editedAt = Date(); model.saveGraphRecord(work)
                }
            }
            if let item {
                if entry == .details {
                    var metadata = model.projectMetadata(for: item)
                    if let value = draft.answers["domain"] { metadata.domain = value }
                    if let value = draft.answers["Type"] { metadata.projectType = value }
                    if let value = draft.answers["Status"] { metadata.status = value }
                    if let value = draft.answers["Phase"] { metadata.phase = value }
                    let related = model.projectRecord(for: item).map { model.projectStore.relatedProjectIDs(for: $0.id) } ?? []
                    model.saveProjectMetadata(metadata, relatedProjectIDs: related, for: item)
                }
                if entry == .scoring, let local = model.projectRecord(for: item) {
                    for metric in MetricDefinition.all { if let raw = draft.answers[metric.id], let rating = Int(raw) { model.setRating(rating, metric: metric, for: local) } }
                }
            }
            if var current = currentProject, let source = model.graphSource(for: current), entry != .planning {
                for (name, value) in draft.answers {
                    if entry == .details, let property = source.property(named: name) {
                        let type = property.definition["type"].string ?? ""
                        current.set(name, value: type == "multi_select" ? ProjectJSON([["name": value]]) : ProjectJSON(["name": value]), source: source)
                    }
                    if entry == .media { current.set(name, value: ProjectJSON([["id": value]]), source: source) }
                    if entry == .scoring, let metric = MetricDefinition.all.first(where: { $0.id == name }), let rating = Double(value) { current.set(metric.displayName, value: .number(rating), source: source) }
                }
                current.editedAt = Date(); model.saveGraphRecord(current)
            }
            draft = .init(); persist(); await draftPersistence?.value; if error == nil { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}

struct ProjectZenButton: View {
    var item: WorkspaceItem?
    var project: ProjectGraphRecord?
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: { Label("Zen mode", systemImage: "sparkle") }
            .buttonStyle(.borderless).fixedSize()
            .sheet(isPresented: $presented) { ProjectZenView(item: item, project: project) }
    }
}
