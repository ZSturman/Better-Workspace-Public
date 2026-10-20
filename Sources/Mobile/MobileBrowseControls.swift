import SwiftUI
import BetterWorkspaceCore

struct MobileBrowseControls: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Binding var query: MobileBrowseQuery
    let ideas: Bool
    @State private var showsDownloads = false
    private var preferenceKey: String { "mobile.browse." + (ideas ? "ideas" : "projects") }
    init(query: Binding<MobileBrowseQuery>, ideas: Bool) {
        _query = query; self.ideas = ideas
    }
    var body: some View {
        Menu {
            Menu("Group by") {
                ForEach(MobileBrowseGroup.allCases.filter { ideas || $0 != .potential }) { value in
                    Button { query.group = value } label: {
                        if query.group == value { Label(value.title, systemImage: "checkmark") } else { Text(value.title) }
                    }
                }
            }
            Menu("Sort by") {
                ForEach(MobileBrowseSort.allCases) { value in
                    Button { query.sort = value } label: {
                        if query.sort == value { Label(value.title, systemImage: "checkmark") } else { Text(value.title) }
                    }
                }
            }
            Toggle("Ascending", isOn: $query.ascending).disabled(query.sort == .recommended)
            Divider()
            filter("Domain", selection: $query.domain, options: model.propertyOptions["domain"] ?? [])
            filter("Status", selection: $query.status, options: model.propertyOptions["Status"] ?? [])
            filter("Phase", selection: $query.phase, options: model.propertyOptions["Phase"] ?? [])
            if ideas {
                Menu("Potential") {
                    Button("All potentials") { query.potential = "" }
                    Button("Unclassified") { query.potential = "unclassified" }
                    ForEach(IdeaPromotionKind.allCases) { value in Button(value.title) { query.potential = value.rawValue } }
                }
            }
            Divider()
            let area = ideas ? "Ideas" : "Projects"
            Button("Offline access for " + area, systemImage: "arrow.down.circle") { showsDownloads = true }
            Button("Reset view") { let search = query.search; query = .init(); query.search = search }
        } label: {
            Label("Filter & sort", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }.accessibilityIdentifier(ideas ? "ideas.filterSort" : "projects.filterSort")
            .sheet(isPresented: $showsDownloads) {
                NavigationStack {
                    List { MobileDownloadSection(entry: MobileWorkspaceEntry(path: ideas ? "Ideas" : "Projects", parentPath: nil, name: ideas ? "Ideas" : "Projects", isDirectory: true, revision: 0)) }
                        .navigationTitle("Offline access")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsDownloads = false } } }
                }
            }
            .onAppear {
                if let value = try? JSONDecoder().decode(MobileBrowseQuery.self, from: Data((model.overviewDefaults.string(forKey: preferenceKey) ?? "").utf8)) {
                    let search = query.search; query = value; query.search = search
                }
            }
            .onChange(of: query) { _, value in
                var stored = value; stored.search = ""
                model.overviewDefaults.set(String(decoding: (try? JSONEncoder().encode(stored)) ?? Data(), as: UTF8.self), forKey: preferenceKey)
            }
    }
    private var filtered: Bool { !query.domain.isEmpty || !query.potential.isEmpty || !query.status.isEmpty || !query.phase.isEmpty }
    private func filter(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        Menu(title) {
            Button(title == "Status" ? "All statuses" : "All " + title.lowercased() + "s") { selection.wrappedValue = "" }
            ForEach(Array(Set(options + (selection.wrappedValue.isEmpty ? [] : [selection.wrappedValue]))).sorted(), id: \.self) { value in Button(value) { selection.wrappedValue = value } }
        }
    }
}
