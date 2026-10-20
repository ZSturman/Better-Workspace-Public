import SwiftUI
import BetterWorkspaceCore

/// A named vocabulary: choose an existing value, or deliberately add one.
struct WorkspaceChoiceField: View {
    let title: String
    @Binding var selection: String
    var suggestions: [String] = []
    var identifier = ""
    @AppStorage private var saved: String
    @State private var adding = false
    @State private var newValue = ""

    init(_ title: String, selection: Binding<String>, suggestions: [String] = [], identifier: String = "", store: UserDefaults? = nil) {
        self.title = title; _selection = selection; self.suggestions = suggestions; self.identifier = identifier
        _saved = AppStorage(wrappedValue: "[]", "workspace.choices." + title.lowercased(), store: store)
    }
    private var custom: [String] { (try? JSONDecoder().decode([String].self, from: Data(saved.utf8))) ?? [] }
    private var options: [String] {
        var values: [String] = []
        for value in [selection] + suggestions + custom where !value.isEmpty {
            if !values.contains(where: { TagMatching.equivalent($0, value) }) { values.append(value) }
        }
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var body: some View {
        Menu {
                Button("Not set") { selection = "" }
                ForEach(options, id: \.self) { value in
                    Button { selection = value } label: {
                        if value == selection { Label(value, systemImage: "checkmark") } else { Text(value) }
                    }
                }
                Divider()
                Button("Add new \(title.lowercased())…", systemImage: "plus") { newValue = ""; adding = true }
            } label: {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    Text(selection.isEmpty ? "Not set" : selection)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .accessibilityLabel(title).accessibilityValue(selection.isEmpty ? "Not set" : selection)
            .accessibilityIdentifier(identifier)
        .alert("Add \(title.lowercased())", isPresented: $adding) {
            TextField(title, text: $newValue)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.utf8.count <= 200, !value.contains("\n") else { return }
                selection = options.first { TagMatching.equivalent($0, value) } ?? value
                if !custom.contains(selection) { saved = String(decoding: (try? JSONEncoder().encode(custom + [selection])) ?? Data(), as: UTF8.self) }
            }.disabled(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newValue.utf8.count > 200 || newValue.contains("\n"))
        }
    }
}
