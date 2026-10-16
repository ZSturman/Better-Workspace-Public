import Foundation

/// Records where a captured file came from, without creating a sidecar.
///
/// Uses an extended attribute on the file itself rather than a companion `.json`,
/// because the brief rules out scattering metadata files around. xattrs travel with
/// the file through a normal move and are generally preserved by iCloud Drive — but
/// that is not guaranteed, so every read falls back to `.external`, which is the
/// honest answer for "this appeared in the inbox and I don't know how".
public enum SourceMarker {

    public static let attributeName = "com.zacharysturman.betterworkspace.source"

    public static func write(_ source: IngestSource, to url: URL) {
        let value = Array(source.rawValue.utf8)
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return value.withUnsafeBufferPointer { buffer in
                setxattr(path, attributeName, buffer.baseAddress, buffer.count, 0, 0)
            }
        }
    }

    /// Removes the marker.
    ///
    /// Called when an item is classified, so that nothing this app owns rides along into
    /// the organized Workspace — the marker is ingest bookkeeping and its job is done
    /// the moment the item stops being an ingest item.
    public static func clear(from url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return removexattr(path, attributeName, 0)
        }
    }

    public static func read(from url: URL) -> IngestSource? {
        url.withUnsafeFileSystemRepresentation { path -> IngestSource? in
            guard let path else { return nil }
            let length = getxattr(path, attributeName, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: length)
            let read = getxattr(path, attributeName, &buffer, length, 0, 0)
            guard read > 0 else { return nil }
            let raw = String(decoding: buffer.prefix(read), as: UTF8.self)
            return IngestSource(rawValue: raw)
        }
    }
}

/// A short-lived receipt inside an iPhone-created capture folder. iCloud Drive makes a
/// directory visible one child at a time, so a Mac must not file a folder just because
/// its note arrived before a camera image or imported file. The receipt is written last
/// on the phone, checked against the capture intent on the Mac, then deleted when the
/// folder is filed; it never becomes organized Workspace content.
public enum MobileCaptureBundleReceipt {
    static let filename = ".betterworkspace-capture-receipt.json"

    private struct Payload: Codable {
        let children: [String]
    }

    public static func write(children: [String], to bundle: URL) throws {
        let payload = Payload(children: children.sorted())
        let data = try JSONEncoder().encode(payload)
        try data.write(to: bundle.appendingPathComponent(filename), options: .atomic)
    }

    public static func children(at bundle: URL) -> Set<String>? {
        let url = bundle.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.children.isEmpty == false,
              payload.children.allSatisfy({ $0.isEmpty == false && $0.contains("/") == false })
        else { return nil }
        return Set(payload.children)
    }

    public static func hasAllChildren(_ expected: Set<String>, at bundle: URL) -> Bool {
        expected.isEmpty == false && expected.allSatisfy { name in
            let child = bundle.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: child.path) else { return false }
            let values = try? child.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
            ])
            if values?.isUbiquitousItem == true,
               values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: child)
                return false
            }
            return true
        }
    }

    public static func clear(from bundle: URL) {
        try? FileManager.default.removeItem(at: bundle.appendingPathComponent(filename))
    }
}

/// Filename derivation shared by desktop capture and the iOS companion, so a note
/// typed on the phone is named the same way as one typed on the Mac.
public enum CaptureNaming {

    public static func title(fromFirstLine line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard text.isEmpty == false else { return nil }
        let words = text.split(separator: " ").prefix(10).joined(separator: " ")
        let capped = String(words.prefix(60)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? nil : capped
    }

    public static func safeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var collapsed = cleaned
        while collapsed.contains("  ") { collapsed = collapsed.replacingOccurrences(of: "  ", with: " ") }
        if collapsed.isEmpty || collapsed.hasPrefix(".") { return timestampName() }
        return truncated(String(collapsed.prefix(120)), maxBytes: 200)
    }

    /// A filename is limited to 255 *bytes*, not characters. 120 characters of CJK or
    /// emoji is up to 480 bytes, and such a capture or work item simply failed to save.
    /// Cut on a character boundary, leaving room for " 99" and an extension.
    static func truncated(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var result = ""
        for character in name {
            if result.utf8.count + String(character).utf8.count > maxBytes { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    public static func timestampName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return "Capture \(f.string(from: Date()))"
    }

    public static func humanTimestamp() -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date())
    }

    /// Builds the Markdown body for a text capture. The first line becomes the H1 so
    /// the file reads well on its own once it lands in `~/Workspace/Ideas`.
    public static func markdownBody(for text: String) -> (heading: String, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        let derived = title(fromFirstLine: firstLine)
        let heading = derived ?? "Capture \(humanTimestamp())"
        var body = "# \(heading)\n\n"
        if derived != nil {
            let remainder = String(trimmed.dropFirst(firstLine.count)).trimmingCharacters(in: .newlines)
            if remainder.isEmpty == false { body += remainder + "\n" }
        } else {
            body += trimmed + "\n"
        }
        return (heading, body)
    }

    public static func uniqueURL(in directory: URL, base: String, extension ext: String) -> URL {
        func make(_ name: String) -> URL {
            ext.isEmpty ? directory.appendingPathComponent(name)
                        : directory.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var candidate = make(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }
}

/// Capture-only service for the iOS companion.
///
/// Writes real files into the shared ingest folder and nothing else — no database, no
/// Workspace access, no classification. Mobile's whole job is getting the thing out of
/// the user's head and into a folder that syncs.
public final class MobileCaptureService: @unchecked Sendable {

    public struct RecentCaptureOverview: Sendable {
        public let urls: [URL]
        public let totalCount: Int

        public init(urls: [URL], totalCount: Int) {
            self.urls = urls
            self.totalCount = totalCount
        }
    }

    public enum CaptureError: Error, LocalizedError {
        case noDestination
        case emptyBundle
        case writeFailed(String)
        case deleteFailed(String)
        public var errorDescription: String? {
            switch self {
            case .noDestination: return "Pick the shared Better Workspace Inbox folder first."
            case .emptyBundle: return "Add a note, photo, or file before saving."
            case .writeFailed(let m): return "Could not save: \(m)"
            case .deleteFailed(let m): return "Could not delete the capture: \(m)"
            }
        }
    }

    public private(set) var inbox: URL?

    public init(inbox: URL?) {
        self.inbox = inbox
    }

    public func setInbox(_ url: URL) { inbox = url }

    /// Typed or pasted text becomes a real `.md` file. Never only a database row.
    @discardableResult
    public func captureText(_ text: String) throws -> URL {
        guard let inbox else { throw CaptureError.noDestination }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let (heading, body) = CaptureNaming.markdownBody(for: text)
        let url = CaptureNaming.uniqueURL(
            in: inbox,
            base: CaptureNaming.safeFilename(heading),
            extension: "md"
        )
        try coordinatedWrite(to: url) { target in
            try Data(body.utf8).write(to: target, options: .atomic)
        }
        SourceMarker.write(.mobile, to: url)
        return url
    }

    /// Writes through `NSFileCoordinator`.
    ///
    /// The inbox is an iCloud container. A plain `write(to:)` there lands on disk but the
    /// sync daemon is not reliably told about it — observed on a real device, where a
    /// capture sat locally and never reached the Mac. A coordinated write registers the
    /// change and the upload starts immediately.
    private func coordinatedWrite(to url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { target in
            do { try body(target) } catch { writeError = error }
        }
        if let writeError { throw CaptureError.writeFailed(writeError.localizedDescription) }
        if let coordinationError { throw CaptureError.writeFailed(coordinationError.localizedDescription) }
    }

    @discardableResult
    public func captureData(_ data: Data, preferredName: String, extension ext: String) throws -> URL {
        guard let inbox else { throw CaptureError.noDestination }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let base = preferredName.isEmpty ? CaptureNaming.timestampName() : preferredName
        let url = CaptureNaming.uniqueURL(in: inbox, base: CaptureNaming.safeFilename(base), extension: ext)
        try coordinatedWrite(to: url) { target in
            try data.write(to: target, options: .atomic)
        }
        SourceMarker.write(.mobile, to: url)
        return url
    }

    @discardableResult
    public func captureFile(at sourceURL: URL, title: String = "") throws -> URL {
        guard let inbox else { throw CaptureError.noDestination }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let base = title.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : title
        let url = CaptureNaming.uniqueURL(in: inbox, base: CaptureNaming.safeFilename(base),
                                         extension: sourceURL.pathExtension)
        try coordinatedWrite(to: url) { target in
            try FileManager.default.copyItem(at: sourceURL, to: target)
        }
        SourceMarker.write(.mobile, to: url)
        return url
    }

    /// Saves one composed capture as a single Inbox folder. The optional note and every
    /// staged attachment become children, so the Mac files the whole thought together.
    @discardableResult
    public func captureBundle(note: String, attachmentURLs: [URL]) throws -> URL {
        guard let inbox else { throw CaptureError.noDestination }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false || attachmentURLs.isEmpty == false else { throw CaptureError.emptyBundle }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let title = trimmed.isEmpty ? CaptureNaming.timestampName()
            : CaptureNaming.markdownBody(for: trimmed).heading
        let bundle = CaptureNaming.uniqueURL(in: inbox, base: CaptureNaming.safeFilename(title), extension: "")
        do {
            try coordinatedWrite(to: bundle) { target in
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                if trimmed.isEmpty == false {
                    let body = CaptureNaming.markdownBody(for: trimmed).body
                    try Data(body.utf8).write(to: target.appendingPathComponent("Note.md"), options: .atomic)
                }
                for source in attachmentURLs {
                    let destination = CaptureNaming.uniqueURL(
                        in: target,
                        base: CaptureNaming.safeFilename(source.deletingPathExtension().lastPathComponent),
                        extension: source.pathExtension
                    )
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                let children = try FileManager.default.contentsOfDirectory(atPath: target.path)
                    .filter { $0 != MobileCaptureBundleReceipt.filename }
                try MobileCaptureBundleReceipt.write(children: children, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            throw error
        }
        SourceMarker.write(.mobile, to: bundle)
        return bundle
    }

    /// Deletes exactly one direct child of this capture service's Inbox. The companion
    /// has no Workspace access, so a stale UI row cannot target an organized file.
    public func deleteCapture(at url: URL) throws {
        guard let inbox, url.deletingLastPathComponent().canonicalPath == inbox.canonicalPath else {
            throw CaptureError.deleteFailed("That item is no longer in this Inbox.")
        }
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forDeleting, error: &coordinationError
        ) { target in
            do { try FileManager.default.removeItem(at: target) } catch { deleteError = error }
        }
        if let deleteError { throw CaptureError.deleteFailed(deleteError.localizedDescription) }
        if let coordinationError { throw CaptureError.deleteFailed(coordinationError.localizedDescription) }
    }

    /// What the phone has sent, so the user can see the queue without the Mac.
    public func recentCaptures(limit: Int = 30) -> [URL] {
        recentCaptureOverview(limit: limit)?.urls ?? []
    }

    /// Reads the inbox once and returns both the visible recent captures and the full
    /// item count.  The caller is responsible for keeping this iCloud-backed read off
    /// the main actor.
    ///
    /// `nil` means the inbox could not be read: there is no destination yet, or the
    /// iCloud file provider would not answer. That is not the same as an empty inbox,
    /// and conflating the two published a confident zero to the widget and to the
    /// Capture screen's count every time a cold provider declined a listing.
    public func recentCaptureOverview(limit: Int = 30) -> RecentCaptureOverview? {
        guard let inbox,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return nil }
        // One pass, and one modification-date read per entry: this runs against an iCloud
        // folder, where every resourceValues call can reach the file provider.
        let dated = entries
            .filter { NoiseFilter.isForeignMetadata(name: $0.lastPathComponent) == false }
            .map { url -> (url: URL, modified: Date) in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return (url, values?.contentModificationDate ?? .distantPast)
            }
        let visible = dated
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map(\.url)
        return RecentCaptureOverview(urls: visible, totalCount: dated.count)
    }
}
