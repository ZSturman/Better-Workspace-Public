import Foundation
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers
import BetterWorkspaceCore

/// A timeout and Quick Look's callback can race. Resume exactly once.
private final class MobilePreviewCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    init(_ continuation: CheckedContinuation<CGImage?, Never>) { self.continuation = continuation }
    func finish(_ image: CGImage?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: image)
    }
}

extension AppModel {
    func loadedMobileProjectPreviews() async -> [String: [MobileFilePreview]] {
        let db = database
        return await Task.detached(priority: .utility) {
            let rows = (try? db.query("SELECT project_id, payload FROM mobile_project_previews", row: { ($0.string(0), $0.string(1)) })) ?? []
            var result: [String: [MobileFilePreview]] = [:]
            for (id, payload) in rows {
                if let data = payload.data(using: .utf8), let previews = try? JSONDecoder().decode([MobileFilePreview].self, from: data) { result[id] = previews }
            }
            return result
        }.value
    }

    /// Explicit requests only: bounded directory listings and locally available files.
    /// Generates no workspace writes, remote fetches or recursive scans.
    func prepareMobileProjectPreviews(_ entry: MobileWorkspaceEntry) async throws {
        let root = try MobilePlanningFiles.resolve(entry.path, workspace: workspace)
        guard let project = projects().first(where: { $0.url.canonicalPath == root.canonicalPath }),
              let id = projectRecord(for: project)?.id, id == entry.projectDetails?.projectID else { throw MobilePlanningFiles.Error.conflict }
        try await prepareMobilePreviews(path: entry.path, root: root, id: id)
    }

    func prepareMobileIdeaPreviews(_ original: MobileIdea) async throws {
        let root = try MobilePlanningFiles.resolve(original.path, workspace: workspace)
        guard let item = items(for: .ideas).first(where: { $0.url.canonicalPath == root.canonicalPath }),
              original.serviceID == nil || original.serviceID == ideaRecord(for: root)?.id else { throw MobilePlanningFiles.Error.conflict }
        try await prepareMobilePreviews(path: original.path, root: root, id: "idea:" + (original.serviceID ?? item.id))
    }

    private func prepareMobilePreviews(path: String, root: URL, id: String) async throws {
        let supported = Set(["png", "jpg", "jpeg", "heic", "gif", "webp", "pdf", "mov", "mp4", "m4v", "md", "markdown", "txt", "swift", "json", "py"])
        let textTypes = Set(["md", "markdown", "txt", "swift", "json", "py"])
        var files: [WorkspaceItem] = []
        let isDirectory = await Task.detached(priority: .utility) { (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.value
        if !isDirectory, let item = await fs.makeItem(url: root), item.isContentLocal, supported.contains(root.pathExtension.lowercased()) { files = [item] }
        for suffix in isDirectory ? ["", "/Media", "/docs/images"] : [] {
            guard let directory = try? MobilePlanningFiles.resolve(path + suffix, workspace: workspace),
                  let children = await FilesystemService.items(inDirectory: directory, timeout: .seconds(2)) else { continue }
            files += children.filter { !$0.isDirectory && $0.isContentLocal && supported.contains($0.url.pathExtension.lowercased()) }
        }
        // Stable choice, with actual visual media before source files.
        files.sort { lhs, rhs in
            let left = !textTypes.contains(lhs.url.pathExtension.lowercased())
            let right = !textTypes.contains(rhs.url.pathExtension.lowercased())
            return left != right ? left : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        var previews: [MobileFilePreview] = []
        for file in files.prefix(6) {
            guard let path = workspaceRelativePath(for: file.url),
                  let safe = try? MobilePlanningFiles.resolve(path, workspace: workspace), safe.canonicalPath == file.url.canonicalPath else { continue }
            var preview = MobileFilePreview(path: path, name: file.name, modifiedAt: file.rawModifiedAt)
            if textTypes.contains(file.url.pathExtension.lowercased()) {
                preview.text = await Task.detached(priority: .utility) {
                    guard let handle = try? FileHandle(forReadingFrom: safe) else { return nil as String? }
                    defer { try? handle.close() }
                    guard let data = try? handle.read(upToCount: 4096) else { return nil }
                    return String(decoding: data, as: UTF8.self)
                }.value
            } else {
                let request = QLThumbnailGenerator.Request(fileAt: safe, size: CGSize(width: 320, height: 320), scale: 1, representationTypes: .thumbnail)
                let image: CGImage? = await withCheckedContinuation { continuation in
                    let completion = MobilePreviewCompletion(continuation)
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in completion.finish(rep?.cgImage) }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        completion.finish(nil)
                        QLThumbnailGenerator.shared.cancel(request)
                    }
                }
                if let image {
                    preview.jpeg = await Task.detached(priority: .utility) {
                        let data = NSMutableData()
                        guard image.width <= 320, image.height <= 320 else { return nil as Data? }
                        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil as Data? }
                        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
                        guard CGImageDestinationFinalize(destination), data.length <= 32_768 else { return nil }
                        return data as Data
                    }.value
                }
            }
            if preview.text != nil || preview.jpeg != nil { previews.append(preview) }
        }
        let payload = String(decoding: try JSONEncoder().encode(previews), as: UTF8.self)
        try database.transaction {
            try database.run("INSERT INTO mobile_project_previews(project_id,payload,updated_at) VALUES (?,?,?) ON CONFLICT(project_id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at", [.text(id), .text(payload), .double(Date().timeIntervalSince1970)])
            // At most ten requested projects/ideas: <= 1.9 MB of binary thumbnails in all.
            try database.run("DELETE FROM mobile_project_previews WHERE project_id NOT IN (SELECT project_id FROM mobile_project_previews ORDER BY updated_at DESC LIMIT 10)")
        }
    }
}
