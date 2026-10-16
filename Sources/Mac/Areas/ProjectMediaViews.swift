import SwiftUI
import AppKit
import AVKit
import CryptoKit
import UniformTypeIdentifiers
import BetterWorkspaceCore

/// Previews belong to the app, never to an organized project directory.
actor ProjectPreviewCache {
    static let shared = ProjectPreviewCache()
    private var inFlight: [URL: Task<URL, Error>] = [:]
    func cachedFile(for url: URL) -> URL? {
        guard let root = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        let key = SHA256.hash(data: Data(ProjectMediaResolver.cacheIdentity(for: url).utf8)).map { String(format: "%02x", $0) }.joined()
        let target = root.appendingPathComponent("BetterWorkspace/ProjectPreviews").appendingPathComponent(key).appendingPathExtension(url.pathExtension)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }
    func file(for url: URL) async throws -> URL {
        if url.isFileURL { return url }
        if let task = inFlight[url] { return try await task.value }
        let task = Task<URL, Error> {
            let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("BetterWorkspace/ProjectPreviews", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let key = SHA256.hash(data: Data(ProjectMediaResolver.cacheIdentity(for: url).utf8)).map { String(format: "%02x", $0) }.joined()
            let target = root.appendingPathComponent(key).appendingPathExtension(url.pathExtension)
            if FileManager.default.fileExists(atPath: target.path) { return target }
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            let limit = 25 * 1024 * 1024
            guard response.expectedContentLength <= Int64(limit) else { throw NotionProjectSync.SyncError.unsupported("Preview exceeds the 25 MB cache limit. Open the original resource instead.") }
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > limit { throw NotionProjectSync.SyncError.unsupported("Preview exceeds the 25 MB cache limit.") } }
            try data.write(to: target, options: .atomic)
            return target
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }
}

extension AppModel {
    func addProjectMedia(from selected: URL, to project: ProjectGraphRecord, replacing existing: ProjectGraphRecord? = nil) async throws {
        guard let source = graphSources.first(where: { $0.kind == .assets }), let preview = source.property(named: "preview") else { throw NotionProjectSync.SyncError.unsupported("Import the Assets source before adding media.") }
        let root = workspace.root, ingest = ingest
        let localFolder = project.localPath.map { URL(fileURLWithPath: $0) }
        let externalDestination = localFolder ?? workspace.url(forArea: "Assets")
        let file = try await Task.detached { () -> URL in
            let path = selected.canonicalPath, rootPath = root.canonicalPath
            if path.hasPrefix(rootPath + "/") { return selected }
            let imported = try ingest.importItem(at: selected)
            return try ingest.classify(imported, intoDirectory: externalDestination, renamingTo: nil)
        }.value
        if let localFolder, file.canonicalPath.hasPrefix(localFolder.canonicalPath + "/") {
            let store = try ProjectGraphStore(database: database)
            _ = try ProjectMediaImport.register(file: file, project: project, sources: graphSources, store: store, workspaceRoot: root, replacing: existing)
            reloadProjectGraph()
            return
        }
        let attributes = try await Task.detached { try FileManager.default.attributesOfItem(atPath: file.path) }.value
        var asset = existing ?? .init(sourceID: source.id, kind: .assets)
        if existing == nil {
            for (name, definition) in source.schema.object where definition["type"].string == "title" { asset.set(name, value: ProjectJSON([["type": "text", "text": ["content": file.deletingPathExtension().lastPathComponent]]]), source: source) }
        }
        let projectStorage = localFolder.map { file.canonicalPath.hasPrefix($0.canonicalPath + "/") } ?? false
        let declaredRoot = projectStorage ? localFolder! : root
        let relative = String(file.canonicalPath.dropFirst(declaredRoot.canonicalPath.count + 1))
        asset.set("relative path", value: ProjectJSON([["type": "text", "text": ["content": relative]]]), source: source)
        asset.set("storage", value: ProjectJSON(["name": projectStorage ? "Project" : "Workspace"]), source: source)
        asset.set("storage project", value: ProjectJSON(projectStorage ? [["id": project.pageID ?? project.id]] : []), source: source)
        if existing == nil, let type = UTType(filenameExtension: file.pathExtension) {
            let name = type.conforms(to: .image) ? "image" : type.conforms(to: .movie) ? "video" : type.conforms(to: .audio) ? "audio" : type.conforms(to: .pdf) ? "pdf" : "file"
            asset.set("type", value: ProjectJSON(["name": name]), source: source)
        }
        for (name, schema) in source.schema.object where schema["type"].string == "relation" && schema["relation"]["data_source_id"].string == project.sourceID {
            if name.lowercased() != "storage project" && name.lowercased().contains("project") && !["thumbnail", "poster", "banner", "icon", "hero"].contains(where: { name.lowercased().contains($0) }) {
                var relations = asset.value(name, source: source)["relation"].array
                let id = project.pageID ?? project.id
                if !relations.contains(where: { $0["id"].string == id }) { relations.append(ProjectJSON(["id": id])) }
                asset.set(name, value: .array(relations), source: source)
            }
        }
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        asset.pendingUploads = [.init(propertyID: preview.id, url: file, contentType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream", byteCount: bytes, modifiedAt: attributes[.modificationDate] as? Date)]
        asset.editedAt = Date(); saveGraphRecord(asset, replacingUploads: true)
    }
    func resolveProjectMedia(_ asset: ProjectGraphRecord, allowExpiredPreview: Bool = false) async -> ProjectMediaResolution? {
        guard let source = graphSource(for: asset) else { return nil }
        let roots = Dictionary(uniqueKeysWithValues: graphRecords.filter { $0.kind == .projects && $0.pageID != nil && $0.localPath != nil }.map { (ProjectGraph.normalizedID($0.pageID!), URL(fileURLWithPath: $0.localPath!)) })
        let assetID = ProjectGraph.normalizedID(asset.pageID ?? asset.id)
        let relatedRoots = graphRecords.filter { $0.kind == .projects && $0.localPath != nil }.compactMap { project -> URL? in
            guard let projectSource = graphSource(for: project) else { return nil }
            let references = ["thumbnail", "banner", "icon", "hero", "poster", "assets"].flatMap {
                project.value($0, source: projectSource)["relation"].array.compactMap { $0["id"].string.map(ProjectGraph.normalizedID) }
            }
            return references.contains(assetID) ? project.localPath.map { URL(fileURLWithPath: $0) } : nil
        }
        var current = asset
        // Refreshing a signed URL changes transport state, not the accepted media assignment.
        for (id, remote) in asset.remote where remote.comparable == asset.local[id]?.comparable { current.local[id] = remote }
        let workspaceRoot = workspace.root, snapshot = current
        return await Task.detached { ProjectMediaResolver.resolve(snapshot, source: source, workspaceRoot: workspaceRoot, projectRoots: roots, relatedProjectRoots: relatedRoots, allowExpiredPreview: allowExpiredPreview) }.value
    }
    func openProjectMedia(_ asset: ProjectGraphRecord) async {
        do {
            var resolution = await resolveProjectMedia(asset)
            if resolution?.url == nil, let expired = await resolveProjectMedia(asset, allowExpiredPreview: true), let url = expired.url,
               let cached = await ProjectPreviewCache.shared.cachedFile(for: url) { open(cached); return }
            if resolution?.url == nil { resolution = await resolveProjectMedia(try await refreshProjectMedia(asset)) }
            guard let url = resolution?.url else { throw NotionProjectSync.SyncError.unsupported("No available local file or uploaded preview for \(asset.title). Check its declared path or replace the media.") }
            open(url)
        } catch { lastError = error.localizedDescription }
    }
    func refreshProjectMedia(_ asset: ProjectGraphRecord) async throws -> ProjectGraphRecord {
        guard let token = SecretStore.read(), let pageID = asset.pageID, let source = graphSource(for: asset) else { return asset }
        let store = try ProjectGraphStore(database: database), owner = "pid:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        guard try store.acquire(owner: owner) else { throw NotionProjectSync.SyncError.busy }
        defer { try? store.release(owner: owner) }
        let client = NotionClient(token: token)
        let page = try await client.completeProperties(try await client.graphRequest("pages/\(pageID)"))
        try store.ingest(pages: [page], source: source); reloadProjectGraph()
        return try store.record(id: asset.id) ?? asset
    }
}

struct ProjectAssetPreview: View {
    @Environment(AppModel.self) private var model
    let asset: ProjectGraphRecord
    let height: CGFloat
    @State private var image: NSImage?
    @State private var playableURL: URL?
    @State private var resolution: ProjectMediaResolution?
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .background(Color.white)
                        .accessibilityLabel(asset.title).accessibilityIdentifier("projects.media.preview.\(asset.id)")
                }
                else if let playableURL { VideoPlayer(player: AVPlayer(url: playableURL)) }
                else { RoundedRectangle(cornerRadius: 8).fill(.quaternary).overlay {
                    if loading { ProgressView() } else { Label(error == nil ? "Preview unavailable" : "Preview failed", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
                } }
            }.frame(maxWidth: .infinity).frame(height: height).clipped()
            if let path = resolution?.staleLocalPath {
                Label(resolution?.url == nil ? "Local path unavailable" : "Local path unavailable · using uploaded preview", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.secondary).help(path)
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }.task(id: asset.id + (asset.editedAt?.description ?? "")) { await load() }
    }
    @MainActor private func load() async {
        loading = true; image = nil; playableURL = nil; error = nil; defer { loading = false }
        do {
            var current = asset
            var resolved = await model.resolveProjectMedia(current)
            if resolved?.url == nil, let expired = await model.resolveProjectMedia(current, allowExpiredPreview: true), let url = expired.url,
               let cached = await ProjectPreviewCache.shared.cachedFile(for: url) {
                resolved = .init(url: cached, staleLocalPath: expired.staleLocalPath, isPreview: true, expiresAt: nil)
            }
            if resolved?.url == nil && current.pageID != nil { current = try await model.refreshProjectMedia(current); resolved = await model.resolveProjectMedia(current) }
            resolution = resolved
            guard let url = resolved?.url else { return }
            image = nil; playableURL = nil; error = nil
            let declaredType = model.graphSource(for: current).map { current.value("type", source: $0).display.lowercased() } ?? ""
            if ["video", "audio"].contains(declaredType) || ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac"].contains(url.pathExtension.lowercased()) {
                // AVPlayer streams remote media on demand; gallery browsing must
                // not download an entire movie into the private preview cache.
                playableURL = url; return
            }
            let file: URL
            do { file = try await ProjectPreviewCache.shared.file(for: url) }
            catch {
                guard !url.isFileURL, current.pageID != nil else { throw error }
                current = try await model.refreshProjectMedia(current)
                guard let fresh = (await model.resolveProjectMedia(current))?.url else { throw error }
                file = try await ProjectPreviewCache.shared.file(for: fresh)
            }
            let result = await Task.detached { NSImage(contentsOf: file) }.value
            image = result
            if result == nil && ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac"].contains(file.pathExtension.lowercased()) { playableURL = file }
        } catch { self.error = error.localizedDescription }
    }
}

struct ProjectPrimaryMedia: View {
    @Environment(AppModel.self) private var model
    let project: ProjectGraphRecord
    let role: String
    let height: CGFloat
    private var asset: ProjectGraphRecord? {
        guard let source = model.graphSource(for: project) else { return nil }
        let roles = role == "portraitHero" ? ["poster portrait", "poster", "hero", "thumbnail", "banner"] : role == "hero" ? ["banner", "poster landscape", "poster", "hero", "thumbnail"] : [role, "thumbnail", "poster"]
        for name in roles {
            let ids = Set(project.value(name, source: source)["relation"].array.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID))
            if let asset = model.graphRecords.first(where: { $0.kind == .assets && ids.contains(ProjectGraph.normalizedID($0.pageID ?? $0.id)) }) { return asset }
        }
        return nil
    }
    var body: some View {
        if let asset { ProjectAssetPreview(asset: asset, height: height) }
        else { RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: height).overlay(Image(systemName: "photo").foregroundStyle(.secondary)) }
    }
}

struct ProjectMediaGallery: View {
    @Environment(AppModel.self) private var model
    let project: ProjectGraphRecord
    var editable = true
    @State private var editing: ProjectGraphRecord?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("Media & Resources").font(.title2.weight(.semibold)); Spacer(); if editable { Button("Add media file…") { chooseFile() }; ProjectRecordCreateMenu(project: project, kinds: [.assets, .resources, .collections]) } }
                let related = model.graphMediaRelated(to: project)
                let collections = related.filter { $0.kind == .collections }
                ForEach(collections) { collection in
                    VStack(alignment: .leading, spacing: 10) {
                        if editable { Button(collection.title) { editing = collection }.font(.headline).buttonStyle(.plain) } else { Text(collection.title).font(.headline) }
                        if let source = model.graphSource(for: collection) {
                            let thumbnail = collection.value("thumbnail", source: source)["relation"].array.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID)
                            if let asset = related.first(where: { $0.kind == .assets && $0.pageID.map(ProjectGraph.normalizedID).map(thumbnail.contains) == true }) { ProjectAssetPreview(asset: asset, height: 180) }
                            let line = collection.value("one liner", source: source).display
                            if !line.isEmpty { Text(line).font(.callout).foregroundStyle(.secondary) }
                        }
                        let members = related.filter { $0.pageID.map(ProjectGraph.normalizedID).map(collection.relatedPageIDs.contains) == true || collection.pageID.map(ProjectGraph.normalizedID).map($0.relatedPageIDs.contains) == true }
                        cards(members.filter { [.assets, .resources].contains($0.kind) })
                        ForEach(members.filter { $0.kind == .projects }) { member in
                            Button { if let path = member.localPath, let local = model.projects().first(where: { $0.url.canonicalPath == path }) { model.openProjectWorkspace(for: local) } else { model.openGraphProjectID = member.id } } label: { Label(member.title, systemImage: "folder") }.buttonStyle(.borderless)
                        }
                    }
                }
                let memberIDs = Set(collections.flatMap { $0.relatedPageIDs })
                cards(related.filter { [.assets, .resources].contains($0.kind) && !($0.pageID.map(ProjectGraph.normalizedID).map(memberIDs.contains) ?? false) })
                if related.filter({ [.assets, .resources, .collections].contains($0.kind) }).isEmpty { ContentUnavailableView("No media or resources", systemImage: "photo.on.rectangle", description: Text("Import related Notion sources in Settings or add a record here.")) }
            }.padding(20)
        }.sheet(item: $editing) { ProjectGraphRecordEditor(record: $0) }
    }
    private func cards(_ records: [ProjectGraphRecord]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 350))], alignment: .leading, spacing: 14) {
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 8) {
                    if record.kind == .assets { ProjectAssetPreview(asset: record, height: 160) }
                    let label = model.graphSource(for: record).map { record.value("label", source: $0).display } ?? ""
                    HStack { Text(label.isEmpty ? record.title : label).font(.headline).lineLimit(2); Spacer(); if editable { Button { editing = record } label: { Image(systemName: "pencil") }.buttonStyle(.borderless) } }
                    if record.kind == .resources, let source = model.graphSource(for: record), let url = URL(string: record.value("url", source: source).display), ["https", "http"].contains(url.scheme ?? "") { Link(url.host ?? "Open resource", destination: url).font(.caption) }
                    if record.kind == .assets { Button("Open media") { Task { await model.openProjectMedia(record) } }.buttonStyle(.borderless).font(.caption) }
                    if editable && record.kind == .assets {
                        Menu("Media actions") {
                            Button("Replace media file…") { chooseFile(replacing: record) }
                            if let source = model.graphSource(for: project) { ForEach(["thumbnail", "poster", "hero", "banner", "icon"].filter { source.property(named: $0) != nil }, id: \.self) { role in
                                Button("Use as \(role)") { var current = model.graphRecords.first { $0.id == project.id } ?? project; current.set(role, value: ProjectJSON([["id": record.pageID ?? record.id]]), source: source); current.editedAt = Date(); model.saveGraphRecord(current) }
                            } }
                        }.font(.caption)
                    }
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func chooseFile(replacing existing: ProjectGraphRecord? = nil) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Workspace files are registered in place. External files are copied through ingest into the linked project folder, or Workspace/Assets for projects without a folder. Replacements preserve previous originals."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in do { try await model.addProjectMedia(from: url, to: project, replacing: existing) } catch { model.lastError = error.localizedDescription } }
    }
}
