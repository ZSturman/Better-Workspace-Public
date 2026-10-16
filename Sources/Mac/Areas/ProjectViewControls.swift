import SwiftUI
import BetterWorkspaceCore

struct ProjectSavedView: Codable, Identifiable {
    var id = UUID()
    var name: String
    var preferences: ProjectBrowserPreferences
    static func load() -> [Self] {
        guard let data = TestIsolation.defaults.data(forKey: "projects.savedViews") else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
    static func save(_ views: [Self]) {
        if let data = try? JSONEncoder().encode(views) { TestIsolation.defaults.set(data, forKey: "projects.savedViews") }
    }
}

struct ProjectContextHelp: View {
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(.secondary) }
            .buttonStyle(.plain).help(text).accessibilityLabel("More information")
            .popover(isPresented: $showing) { Text(text).font(.callout).padding(16).frame(width: 310) }
    }
}

struct ProjectFilterEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: ProjectBrowserPreferences
    let rows: [ProjectBrowserRow]
    @State private var field = "status"
    @State private var valueSearch = ""
    static let fields = ["status", "phase", "domain", "type", "tags", "workMode", "currentWork", "nextWork", "blockers", "completionModel", "maintenanceCadence", "priority", "rated", "kind", "source"]
    private var rule: ProjectPropertyFilter {
        preferences.propertyFilters?.first { $0.field == field } ?? .init(field: field)
    }
    private var values: [String] {
        Set(rows.flatMap { $0.queryRecord.selected(field) }).union(rule.values).sorted()
            .filter { valueSearch.isEmpty || $0.localizedCaseInsensitiveContains(valueSearch) }
    }
    private func update(_ rule: ProjectPropertyFilter) {
        var rules = preferences.propertyFilters ?? []
        rules.removeAll { $0.field == field }
        rules.append(rule)
        preferences.propertyFilters = rules
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filter projects").font(.headline)
                Spacer()
                Button("Clear all") { preferences.propertyFilters = []; preferences.activity = .all; preferences.matchAny = false; preferences.focusedDomain = nil }
            }
            Picker("Match properties", selection: Binding(get: { preferences.matchAny ?? false }, set: { preferences.matchAny = $0 })) {
                Text("All (AND)").tag(false); Text("Any (OR)").tag(true)
            }.pickerStyle(.segmented)
            Picker("Property", selection: $field) {
                ForEach(Self.fields, id: \.self) { key in
                    let active = preferences.propertyFilters?.contains { $0.field == key && !$0.values.isEmpty } == true
                    Text(ProjectBrowserView.title(key) + (active ? " ●" : "")).tag(key)
                }
            }.accessibilityIdentifier("projects.filter.property").onChange(of: field) { _, _ in valueSearch = "" }
            Picker("Rule", selection: Binding(get: { rule.operation }, set: { operation in var value = rule; value.operation = operation; update(value) })) {
                ForEach(ProjectPropertyFilter.Operation.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Find a value", text: $valueSearch).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        Toggle(value, isOn: Binding(get: { rule.values.contains(value) }, set: { enabled in
                            var next = rule
                            if enabled { next.values.insert(value) } else { next.values.remove(value) }
                            update(next)
                        })).toggleStyle(.checkbox).accessibilityIdentifier("projects.filter." + field + "." + value)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 132)
            Button("Clear this property") { update(.init(field: field)) }
            Divider()
            Picker("Activity / work", selection: Binding(get: { preferences.activity ?? .all }, set: { preferences.activity = $0 })) {
                ForEach(ProjectActivityFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("Activity and search always narrow the matching properties. Unknown observations do not count as zero or idle. Unfinished work counts recorded tasks, features and milestones, not estimated effort.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(18).frame(width: 370)
    }
}
