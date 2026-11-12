import Foundation

/// One explicit mobile Save, with a stable identity across app/extension retries.
public struct MobileIdeaCapture: Codable, Sendable {
    public let intent: MobileWorkspaceIntent
    public let title: String

    public static func transferName(_ id: UUID) -> String { "cloud-idea-" + id.uuidString }

    public static func transferName(for intent: MobileWorkspaceIntent) -> String? {
        let name = transferName(intent.id)
        return intent.kind == .captureClassification && intent.captureKind == .idea
            && intent.captureName == name && intent.captureDestinationPath == nil ? name : nil
    }

    static func receipt(_ name: String, filedName: String? = nil) -> String {
        "filed-" + name + (filedName.map { "/" + $0 } ?? "")
    }

    #if os(iOS)
    static func stage(_ entries: [CaptureDraftEntry], title: String, tagIDs: Set<String>, in root: URL) throws -> Self {
        let id = UUID()
        let name = transferName(id)
        let intent = MobileWorkspaceIntent(id: id, kind: .captureClassification, targetPath: nil,
            baseRevision: nil, tagIDs: tagIDs, addTagIDs: [], removeTagIDs: [],
            captureName: name, captureKind: .idea)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-" + id.uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let draft = MobileCaptureService(inbox: staging.appendingPathComponent("content", isDirectory: true)).captureTogether(entries, title: title)
        guard let url = draft.saved.first?.url, let children = MobileCaptureBundleReceipt.children(at: url) else {
            throw MobilePlanningFiles.Error.invalid(draft.failures.first?.message ?? "The idea could not be saved.")
        }
        var total = 0
        var files: [MobileDownloadFile] = []
        guard children.count <= MobileDownloadBundle.maximumFiles else { throw sizeError }
        for child in children.sorted() {
            guard MobileDownloadBundle.safePath(child), !child.contains("/") else { throw sizeError }
            let file = url.appendingPathComponent(child)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= MobileDownloadBundle.maximumBytes - total else { throw sizeError }
            let bytes = try Data(contentsOf: file)
            total += bytes.count
            files.append(.init(path: child, data: bytes))
        }
        let capture = Self(intent: intent, title: url.lastPathComponent)
        let bundle = MobileDownloadBundle(path: name, title: capture.title, files: files)
        try bundle.write(to: staging.appendingPathComponent("bundle.plist"))
        try JSONEncoder().encode(capture).write(to: staging.appendingPathComponent("capture.json"), options: .atomic)
        try fm.removeItem(at: url.deletingLastPathComponent())
        // Readers skip hidden stages and only see a fully written package.
        try fm.moveItem(at: staging, to: root.appendingPathComponent(id.uuidString, isDirectory: true))
        return capture
    }

    private static var sizeError: Error {
        MobilePlanningFiles.Error.invalid("An idea can sync up to 500 files and 50 MB of attachments. Save a smaller selection.")
    }

    static func pending(in root: URL) -> [(capture: Self, directory: URL)] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                   options: .skipsHiddenFiles)) ?? []
        return entries.compactMap { url -> (Self, URL)? in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let data = try? Data(contentsOf: url.appendingPathComponent("capture.json")),
                  let capture = try? JSONDecoder().decode(Self.self, from: data),
                  capture.intent.id == id, transferName(for: capture.intent) != nil else { return nil }
            return (capture, url)
        }.sorted { $0.0.intent.createdAt < $1.0.intent.createdAt }
    }
    #endif

    private struct FilingProof: Codable {
        let destination: URL
        let staged: URL
        let folderIdentity: FileIdentity
        let parentIdentity: FileIdentity
    }

    public static func checkpointURL(_ id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }

    public static func filedName(_ id: UUID, checkpointDirectory: URL) -> String? {
        let checkpoint = checkpointURL(id, directory: checkpointDirectory)
        guard let data = try? Data(contentsOf: checkpoint),
              let proof = try? JSONDecoder().decode(FilingProof.self, from: data) else { return nil }
        return proof.destination.lastPathComponent
    }

    /// Files the verified asset directly into Ideas. The identity on the staged folder
    /// makes a retry after publication but before the database receipt reuse that folder.
    public static func file(_ bundle: MobileDownloadBundle, id: UUID, workspace: WorkspaceLocation,
                            checkpointDirectory: URL) throws -> URL {
        try bundle.validate()
        guard bundle.path == transferName(id), bundle.directories.isEmpty, !bundle.files.isEmpty,
              bundle.files.allSatisfy({ !$0.path.contains("/") }) else {
            throw MobilePlanningFiles.Error.invalid("The idea transfer is incomplete or invalid.")
        }
        let ideas = WorkspaceArea.ideas.directoryName
        let root = try MobilePlanningFiles.resolve(ideas, workspace: workspace)
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw MobilePlanningFiles.Error.invalid("The Ideas area is unavailable.")
        }
        let base = CaptureNaming.safeFilename(bundle.title)
        let original = try MobilePlanningFiles.resolve(ideas + "/" + base, workspace: workspace)
        let alternate = try MobilePlanningFiles.resolve(ideas + "/" + base + " (" + id.uuidString + ")", workspace: workspace)
        let identity = WorkspaceContentIdentity.Value(id: id, kind: .idea)
        let fm = FileManager.default
        let checkpoint = checkpointURL(id, directory: checkpointDirectory)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: checkpoint)
        if fm.fileExists(atPath: checkpoint.path) {
            let proof = try JSONDecoder().decode(FilingProof.self, from: Data(contentsOf: checkpoint))
            guard [original, alternate].contains(where: { $0.canonicalPath == proof.destination.canonicalPath }),
                  FileIdentityResolver.identity(of: root) == proof.parentIdentity else { throw MobilePlanningFiles.Error.conflict }
            if FileIdentityResolver.identity(of: proof.destination) != proof.folderIdentity {
                guard FileIdentityResolver.identity(of: proof.staged) == proof.folderIdentity,
                      try WorkspaceContentIdentity.read(at: proof.staged) == identity else {
                    // If Finder moved the published folder, the stage is also gone.
                    // Keep the transfer pending instead of creating a second idea.
                    throw MobilePlanningFiles.Error.conflict
                }
                guard renameatx_np(AT_FDCWD, proof.staged.path, AT_FDCWD, proof.destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                _ = rmdir(proof.staged.deletingLastPathComponent().path)
            }
            guard try WorkspaceContentIdentity.read(at: proof.destination) == identity else {
                throw MobilePlanningFiles.Error.conflict
            }
            return proof.destination
        }
        let destination = fm.fileExists(atPath: original.path) ? alternate : original
        let document = bundle.files.first { $0.path == IdeaFolderLayout.bundleNoteName }
        let markdown = try document.map { file in
            guard let text = String(data: file.data, encoding: .utf8) else {
                throw MobilePlanningFiles.Error.invalid("The idea note is not readable Markdown.")
            }
            return text
        }
        let attachments = bundle.files.filter { $0.path != IdeaFolderLayout.bundleNoteName }.map { file in
            IdeaFolderLayout.Attachment(name: (file.path as NSString).deletingPathExtension,
                                        ext: (file.path as NSString).pathExtension) { target in
                try file.data.write(to: target, options: .withoutOverwriting)
            }
        }
        try fm.createDirectory(at: checkpointDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try IdeaFileService.publishFolder(at: destination, beforePublish: { staged, parentIdentity in
            guard let folderIdentity = FileIdentityResolver.identity(of: staged) else { throw MobilePlanningFiles.Error.conflict }
            let proof = FilingProof(destination: destination, staged: staged, folderIdentity: folderIdentity, parentIdentity: parentIdentity)
            try JSONEncoder().encode(proof).write(to: checkpoint, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: checkpoint)
            defer { try? handle.close() }
            try handle.synchronize()
        }) { folder in
            try IdeaFolderLayout.build(in: folder, base: destination.lastPathComponent, title: base,
                                       markdown: markdown, attachments: attachments)
            try WorkspaceContentIdentity.write(identity, at: folder)
        }
        return destination
    }
}
