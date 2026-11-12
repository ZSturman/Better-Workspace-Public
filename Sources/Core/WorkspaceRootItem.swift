#if os(macOS)
// Desktop filesystem navigation; mobile continues to use the portable journal.
import Foundation
import Darwin

/// Root navigation only; these names are not portable workspace record identities.
public struct WorkspaceRootItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case application, webpage, file }
    public let url: URL
    public let kind: Kind
    public let links: [URL]
    public let warning: String?
    public let identity: FileIdentity?
    public var id: String { url.lastPathComponent }
    public var title: String { kind == .file ? id : url.deletingPathExtension().lastPathComponent }
    public var symbol: String {
        switch kind { case .application: "app"; case .webpage: "globe"; case .file: FileKind.classify(url: url, isDirectory: false).symbolName }
    }
}

public enum WorkspaceWebPolicy {
    /// No credentials, local files, custom schemes or script URLs from a shortcut.
    public static func webpage(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return parts.url
    }
    public static func allowsNavigation(_ url: URL) -> Bool {
        webpage(url.absoluteString) != nil || url.absoluteString == "about:blank"
    }
    public static func shortcut(named name: String) -> URL? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 512 else { return nil }
        var parts = URLComponents()
        parts.scheme = "shortcuts"; parts.host = "run-shortcut"
        parts.queryItems = [.init(name: "name", value: name)]
        return parts.url
    }
}

public enum WorkspaceRootDiscovery {
    public static func items(in workspace: WorkspaceLocation) -> [WorkspaceRootItem]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: workspace.root,
            includingPropertiesForKeys: [.isDirectoryKey, .isAliasFileKey], options: [.skipsHiddenFiles]) else { return nil }
        return urls.compactMap { url -> WorkspaceRootItem? in
            guard WorkspaceFolderDiscovery.couldBeArea(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isAliasFileKey])
            let app = url.pathExtension.lowercased() == "app" || applicationURL(for: url) != nil
            guard app || values?.isDirectory != true else { return nil }
            let ext = url.pathExtension.lowercased()
            var links: [URL] = [], warning: String?
            if !app, ["webloc", "url", "md", "markdown", "txt"].contains(ext) {
                do { links = try webpageLinks(at: url) }
                catch { warning = error.localizedDescription }
                if links.isEmpty, ["webloc", "url"].contains(ext), warning == nil { warning = "This shortcut has no supported webpage URL. Use an HTTP or HTTPS address." }
            }
            return .init(url: url, kind: app ? .application : !links.isEmpty || ["webloc", "url"].contains(ext) ? .webpage : .file,
                links: links, warning: warning, identity: FileIdentityResolver.identity(of: url))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Resolves only a declared root app/link. No directory crawling or intent metadata.
    public static func applicationURL(for url: URL) -> URL? {
        if url.pathExtension.lowercased() == "app" {
            let target = url.resolvingSymlinksInPath()
            return target.pathExtension.lowercased() == "app" ? target : nil
        }
        if (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true,
           let target = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
           target.pathExtension.lowercased() == "app" { return target }
        return nil
    }

    /// Same bounded formats/parser used by Inbox Review, with exclusive regular-file
    /// reads so discovery cannot block on a FIFO, follow a link or fetch a placeholder.
    public static func webpageLinks(at url: URL) throws -> [URL] {
        guard (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) != .notDownloaded else {
            throw WorkspaceReplicaError.invalid("Download this file in Finder before previewing it.")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceReplicaError.invalid("This link file is unavailable or is a symbolic link.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size <= 32_768 else {
            throw WorkspaceReplicaError.invalid("Webpage shortcuts must be ordinary files of 32 KB or less.")
        }
        let bytes = try handle.read(upToCount: 32_769) ?? Data()
        guard bytes.count <= 32_768 else { throw WorkspaceReplicaError.changed }
        let ext = url.pathExtension.lowercased()
        if ext == "webloc" {
            let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
            return (plist?["URL"] as? String).flatMap(WorkspaceWebPolicy.webpage).map { [$0] } ?? []
        }
        guard let text = String(data: bytes, encoding: .utf8) else { throw WorkspaceReplicaError.invalid("The link file is not readable UTF-8 text.") }
        if ext == "url" {
            let raw = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.uppercased().hasPrefix("URL=") }.map { String($0.dropFirst(4)) } ?? text
            return WorkspaceWebPolicy.webpage(raw).map { [$0] } ?? []
        }
        return WorkspaceInboxReview.ContentParser.parse(text).links.filter { WorkspaceWebPolicy.webpage($0.absoluteString) != nil }
    }
}
#endif
