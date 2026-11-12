import SwiftUI
import BetterWorkspaceCore

struct ProjectDomainBadge: View {
    let domain: String?
    var body: some View {
        let style = ProjectDomainStyle(domain)
        Label(style.title, systemImage: style.symbol).font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(style.color).background(style.color.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(style.color.opacity(0.5), lineWidth: 1)).help(style.title).accessibilityLabel(style.title)
    }
}
struct ProjectDomainStyle {
    let title: String
    let symbol: String
    let color: Color
    init(_ domain: String?) {
        title = domain?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Unassigned domain"
        let value = TagMatching.normalized(title)
        if value.contains("art") || value.contains("design") || value.contains("creative") { symbol = "paintpalette.fill"; color = .purple }
        else if value.contains("tech") || value.contains("software") || value.contains("develop") { symbol = "laptopcomputer"; color = .blue }
        else if value.contains("business") || value.contains("work") { symbol = "briefcase.fill"; color = .orange }
        else if value.contains("personal") || value.contains("life") { symbol = "person.fill"; color = .green }
        else if value.contains("learn") || value.contains("research") { symbol = "book.fill"; color = .teal }
        else if value.contains("music") || value.contains("audio") { symbol = "music.note"; color = .pink }
        else if title == "Unassigned domain" { symbol = "questionmark.diamond"; color = .secondary }
        else {
            symbol = "square.grid.2x2.fill"
            let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .green]
            color = colors[value.utf8.reduce(0) { ($0 + Int($1)) % colors.count }]
        }
    }
}
private extension String { var nilIfBlank: String? { isEmpty ? nil : self } }

struct ProjectTypeField: View {
    @Binding var value: String
    var suggestions: [String]
    var store: UserDefaults? = nil
    @State private var choice = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkspaceChoiceField("Types", selection: $choice, suggestions: suggestions.flatMap { ProjectProperties.types($0) }, identifier: "project.types.add", store: store)
                .onChange(of: choice) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    value = ProjectProperties.types(value + "," + newValue).joined(separator: ", "); choice = ""
                }
            ForEach(ProjectProperties.types(value), id: \.self) { type in
                HStack {
                    Text(type); Spacer()
                    Button { value = ProjectProperties.types(value).filter { $0 != type }.joined(separator: ", ") } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove type " + type)
                }
            }
        }
    }
}

struct ProjectPortfolioFields: View {
    @Binding var details: ProjectPortfolioDetails
    var body: some View {
        flagToggle("Featured", \.featured).accessibilityIdentifier("project.featured")
        flagToggle("In Showcase", \.inShowcase)
        flagToggle("Public", \.isPublic)
        Text("These describe your project. Saving does not publish it.").font(.caption).foregroundStyle(.secondary)
    }
    private func flagToggle(_ title: String, _ path: WritableKeyPath<ProjectPortfolioDetails, Bool?>) -> some View {
        #if os(macOS)
        Toggle(title, isOn: flag(path)).toggleStyle(.checkbox).fixedSize()
        #else
        Toggle(title, isOn: flag(path))
        #endif
    }
    private func flag(_ path: WritableKeyPath<ProjectPortfolioDetails, Bool?>) -> Binding<Bool> {
        Binding(get: { details[keyPath: path] ?? false }, set: { details[keyPath: path] = $0 })
    }
}
struct ProjectLinksFields: View {
    @Binding var details: ProjectPortfolioDetails
    var body: some View {
        urlField("GitHub", path: \.githubURL)
        urlField("Website / portfolio", path: \.websiteURL)
        ForEach(details.customLinks ?? []) { link in
            VStack(alignment: .leading) {
                TextField("Link name (App Store, Notion…)", text: linkBinding(link.id, \.label))
                TextField("https://", text: linkBinding(link.id, \.url))
                HStack {
                    if let destination = link.destination { Link("Open " + link.label, destination: destination) }
                    Spacer()
                    Button("Remove link", role: .destructive) { details.customLinks?.removeAll { $0.id == link.id } }.buttonStyle(.borderless)
                }
            }
        }
        Button("Add link", systemImage: "plus") { details.customLinks = (details.customLinks ?? []) + [ProjectLink()] }
            .disabled((details.customLinks ?? []).count >= 30)
    }
    private func urlField(_ title: String, path: WritableKeyPath<ProjectPortfolioDetails, String?>) -> some View {
        VStack(alignment: .leading) {
            TextField(title, text: Binding(get: { details[keyPath: path] ?? "" }, set: { details[keyPath: path] = $0.isEmpty ? nil : $0 }))
                .accessibilityIdentifier(path == \.githubURL ? "project.links.github" : "project.links.website")
            if let raw = details[keyPath: path], let url = ProjectLink(label: title, url: raw).destination { Link("Open " + title, destination: url) }
        }
    }
    private func linkBinding(_ id: UUID, _ path: WritableKeyPath<ProjectLink, String>) -> Binding<String> {
        Binding(get: { details.customLinks?.first { $0.id == id }?[keyPath: path] ?? "" }, set: { value in
            if let index = details.customLinks?.firstIndex(where: { $0.id == id }) { details.customLinks?[index][keyPath: path] = value }
        })
    }
}
