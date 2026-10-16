import Foundation
import UniformTypeIdentifiers

/// Explicit local registration. Never uploads, accepts incoming fields or changes originals.
public enum ProjectMediaImport {
    public enum Failure: LocalizedError {
        case missingSchema
        public var errorDescription: String? { "The Assets source needs preview, path, storage, type and a project relationship before media can be registered." }
    }
    public static func register(file: URL, project: ProjectGraphRecord, sources: [ProjectGraphSource],
                                store: ProjectGraphStore, workspaceRoot: URL,
                                replacing existing: ProjectGraphRecord? = nil, knownRecords: [ProjectGraphRecord]? = nil) throws -> ProjectGraphRecord {
        guard let source = sources.first(where: { $0.kind == .assets }), let preview = source.property(named: "preview"),
              let projectPath = project.localPath,
              ["relative path", "storage", "storage project", "type"].allSatisfy({ source.property(named: $0) != nil }) else {
            throw Failure.missingSchema
        }
        let path = file.canonicalPath, root = URL(fileURLWithPath: projectPath).canonicalPath
        guard path.hasPrefix(root + "/"), root.hasPrefix(workspaceRoot.canonicalPath + "/"),
              file.resolvingSymlinksInPath().canonicalPath.hasPrefix(URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().canonicalPath + "/"),
              FileManager.default.fileExists(atPath: path), let type = UTType(filenameExtension: file.pathExtension),
              type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .audio) || type.conforms(to: .pdf) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let relations = source.schema.object.filter { name, definition in
            definition["type"].string == "relation" && definition["relation"]["data_source_id"].string == project.sourceID &&
            name.lowercased() != "storage project" && name.lowercased().contains("project") &&
            !["thumbnail", "poster", "banner", "icon", "hero"].contains(where: { name.lowercased().contains($0) })
        }.map(\.key)
        guard !relations.isEmpty else { throw Failure.missingSchema }
        let relative = String(path.dropFirst(root.count + 1)), projectID = project.pageID ?? project.id
        if existing == nil, let duplicate = (try knownRecords ?? store.records()).first(where: { record in
            record.kind == .assets && record.sourceID == source.id &&
            record.value("storage", source: source).display == "Project" &&
            record.value("relative path", source: source).display == relative &&
            record.value("storage project", source: source)["relation"].array.contains(where: {
                $0["id"].string.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(projectID)
            }) && relations.contains(where: { name in
                record.value(name, source: source)["relation"].array.contains(where: {
                    $0["id"].string.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(projectID)
                })
            })
        }) { return duplicate }
        var asset = existing ?? .init(sourceID: source.id, kind: .assets)
        if existing == nil {
            for (name, definition) in source.schema.object where definition["type"].string == "title" {
                asset.set(name, value: ProjectJSON([["type": "text", "text": ["content": file.deletingPathExtension().lastPathComponent]]]), source: source)
            }
        }
        asset.set("relative path", value: ProjectJSON([["type": "text", "text": ["content": relative]]]), source: source)
        asset.set("storage", value: ProjectJSON(["name": "Project"]), source: source)
        asset.set("storage project", value: ProjectJSON([["id": projectID]]), source: source)
        if existing == nil {
            let kind = type.conforms(to: .image) ? "image" : type.conforms(to: .movie) ? "video" : type.conforms(to: .audio) ? "audio" : "pdf"
            asset.set("type", value: ProjectJSON(["name": kind]), source: source)
        }
        for name in relations {
            var values = asset.value(name, source: source)["relation"].array
            if !values.contains(where: { $0["id"].string.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(projectID) }) {
                values.append(ProjectJSON(["id": projectID]))
            }
            asset.set(name, value: .array(values), source: source)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        asset.pendingUploads = [.init(propertyID: preview.id, url: file,
            contentType: type.preferredMIMEType ?? "application/octet-stream",
            byteCount: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date)]
        asset.editedAt = Date()
        try store.save(asset)
        return asset
    }
}
