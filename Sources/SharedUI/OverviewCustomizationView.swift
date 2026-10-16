import SwiftUI
import BetterWorkspaceCore

struct OverviewCustomizationView: View {
    @Binding var encoded: String
    let supported: [OverviewSectionID]
    @Environment(\.dismiss) private var dismiss
    private var layout: OverviewLayout { .load(encoded, defaultOrder: supported) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Simple layout") { encoded = OverviewLayout.simple.encoded }
                    Button("Show all sections") { encoded = OverviewLayout().encoded }
                } footer: { Text("Choose what deserves your attention. Other workspace screens remain available.") }
                Section("Your sections") {
                    ForEach(layout.order.filter { supported.contains($0) }) { section in
                        HStack {
                            Toggle(section.title, isOn: Binding(get: { !layout.hidden.contains(section) }, set: { visible in
                                var next = layout
                                if visible { next.hidden.remove(section) } else { next.hidden.insert(section) }
                                encoded = next.encoded
                            }))
                            .accessibilityIdentifier("overview.visible.\(section.rawValue)")
                            Button { move(section, by: -1) } label: { Image(systemName: "arrow.up") }
                                .accessibilityLabel("Move \(section.title) up")
                                .disabled(layout.order.filter { supported.contains($0) }.first == section)
                            Button { move(section, by: 1) } label: { Image(systemName: "arrow.down") }
                                .accessibilityLabel("Move \(section.title) down")
                                .disabled(layout.order.filter { supported.contains($0) }.last == section)
                        }
                    }
                }
            }
            .navigationTitle("Customize Overview")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 430)
        #endif
    }

    private func move(_ section: OverviewSectionID, by offset: Int) {
        var next = layout
        let supportedOrder = next.order.filter { supported.contains($0) }
        guard let index = supportedOrder.firstIndex(of: section), supportedOrder.indices.contains(index + offset),
              let from = next.order.firstIndex(of: section),
              let to = next.order.firstIndex(of: supportedOrder[index + offset]) else { return }
        next.order.swapAt(from, to); encoded = next.encoded
    }
}
