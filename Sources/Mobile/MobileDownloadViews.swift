import SwiftUI
import QuickLook
import BetterWorkspaceCore

struct MobileDownloadState: Codable, Identifiable {
    var entry: MobileWorkspaceEntry
    var requestID: UUID?
    var copy: MobileOfflineCopy?
    var enabled = true
    var receiptReceived = false
    var error: String?
    var id: String { entry.path }
}

struct MobileDownloadSection: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let entry: MobileWorkspaceEntry
    private var state: MobileDownloadState? { model.download(for: entry.path) }
    var body: some View {
        Section {
            Toggle("Available offline", isOn: Binding(get: { state?.enabled == true }, set: { model.setDownload(entry, enabled: $0) }))
                .disabled(model.isSample).accessibilityIdentifier("download.enabled")
            if let copy = state?.copy {
                NavigationLink { MobileOfflineFilesView(copy: copy) } label: { Label("Open downloaded files", systemImage: "arrow.down.circle.fill") }
                    .accessibilityIdentifier("download.open")
                Text("\(copy.files.count) files · Downloaded \(copy.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            if let state, state.enabled {
                if state.requestID != nil { Label("Waiting for download from the Mac…", systemImage: "arrow.down.circle").font(.caption) }
                if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("Update download", systemImage: "arrow.clockwise") { model.setDownload(entry, enabled: true) }
                    .disabled(state.requestID != nil)
                if state.error != nil, state.requestID != nil {
                    Button("Retry transfer") { Task { await model.refresh() } }
                }
            }
        } header: { Text("Offline access") } footer: {
            Text("Copies stay on this device until removed. The Mac must be online to prepare or update them. Up to 500 files / 50 MB per download; hidden files, metadata, dependencies and build folders are excluded.")
        }
    }
}

struct MobileDownloadsList: View {
    @Environment(MobileWorkspaceModel.self) private var model
    var body: some View {
        List {
            ForEach(model.downloads.filter(\.enabled)) { state in
                if let copy = state.copy {
                    NavigationLink { MobileOfflineFilesView(copy: copy) } label: { Label(copy.title, systemImage: "arrow.down.circle.fill") }
                } else { Label(state.entry.name + " · Waiting for the Mac", systemImage: "arrow.down.circle") }
                if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("Remove download", role: .destructive) { model.setDownload(state.entry, enabled: false) }
            }
            if !model.downloads.contains(where: \.enabled) {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle", description: Text("Enable Available offline on a project, idea, file, folder or category."))
            }
        }.navigationTitle("Downloads").refreshable { await model.refresh() }
    }
}

struct MobileOfflineFilesView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let copy: MobileOfflineCopy
    var parent = ""
    @State private var preview: URL?
    private var items: [(path: String, directory: Bool)] {
        // Virtualize underscore containers here too, retaining original cache paths.
        let paths = Set(copy.files + copy.directories + copy.files.flatMap { path in
            let parts = path.split(separator: "/"); return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        })
        return paths.compactMap { path in
            let directory = !copy.files.contains(path)
            let parts = path.split(separator: "/").map(String.init)
            if directory && parts.last?.hasPrefix("_") == true { return nil }
            var ancestors = Array(parts.dropLast())
            while ancestors.last?.hasPrefix("_") == true { ancestors.removeLast() }
            guard ancestors.joined(separator: "/") == parent else { return nil }
            return (path, directory)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    var body: some View {
        List {
            ForEach(items, id: \.path) { item in
                let name = item.path.split(separator: "/").last.map(String.init) ?? item.path
                if item.directory {
                    NavigationLink { MobileOfflineFilesView(copy: copy, parent: item.path) } label: { Label(name, systemImage: "folder") }
                } else if let url = model.downloadCache.fileURL(copy: copy, path: item.path) {
                    HStack {
                        Button { preview = url } label: { Label(name, systemImage: "doc") }
                        Spacer()
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share " + name)
                    }.buttonStyle(.borderless)
                }
            }
            if items.isEmpty { Text("This downloaded folder is empty.").foregroundStyle(.secondary) }
        }.navigationTitle(parent.isEmpty ? copy.title : URL(fileURLWithPath: parent).lastPathComponent)
            .quickLookPreview($preview)
    }
}
