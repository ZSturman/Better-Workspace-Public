import Foundation

/// The one shape every new idea takes, whichever device or entry point made it:
///
///     Ideas/Garden studio/
///         Garden studio.md
///         Attachments/sketch.png
///
/// The note links each attachment by a relative path, so the folder reads correctly in
/// Finder, any Markdown editor, and later as a project (moving the folder into Projects
/// keeps every link). Ideas already in Ideas are never restructured.
public enum IdeaFolderLayout {
    public static let attachmentsFolder = "Attachments"
    /// The note name a phone capture bundle uses (`MobileCaptureService.captureBundle`).
    static let bundleNoteName = "Note.md"
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp", "svg"]

    /// One file to place under `Attachments/`. `write` receives the final URL.
    public struct Attachment {
        public let name: String
        public let ext: String
        public let write: (URL) throws -> Void
        public init(name: String, ext: String, write: @escaping (URL) throws -> Void) {
            self.name = name; self.ext = ext; self.write = write
        }
    }

    /// Fills an empty (staged) idea folder: `<base>.md` plus `Attachments/`.
    /// Attachment names are made unique within the folder; nothing is overwritten.
    public static func build(in folder: URL, base: String, title: String, markdown: String?, attachments: [Attachment]) throws {
        let fm = FileManager.default
        var placed: [String] = []
        if !attachments.isEmpty {
            let directory = folder.appendingPathComponent(attachmentsFolder, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            for attachment in attachments {
                let target = CaptureNaming.uniqueURL(in: directory, base: CaptureNaming.safeFilename(attachment.name), extension: attachment.ext)
                try attachment.write(target)
                placed.append(target.lastPathComponent)
            }
        }
        let note = self.note(markdown, title: title, attachments: placed)
        try Data(note.utf8).write(to: folder.appendingPathComponent(base).appendingPathExtension("md"), options: .withoutOverwriting)
    }

    /// The note's text: what was written, or a heading, followed by links to any
    /// attachment the text does not already mention.
    public static func note(_ markdown: String?, title: String, attachments: [String]) -> String {
        let written = markdown?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var text = written.isEmpty ? "# \(title)\n" : written + "\n"
        let missing = attachments.filter { !written.contains("(<\(attachmentsFolder)/\($0)>)") }.map(link)
        if !missing.isEmpty {
            text += "\n" + missing.joined(separator: "\n") + "\n"
        }
        return text
    }

    /// `![name](<Attachments/name.png>)`; angle brackets keep names with spaces valid.
    public static func link(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let label = (name as NSString).deletingPathExtension
        let target = "<\(attachmentsFolder)/\(name)>"
        return imageExtensions.contains(ext) ? "![\(label)](\(target))" : "[\(label)](\(target))"
    }

    /// A phone capture bundle: a flat folder made by the capture service (it carries a
    /// receipt, or its note is `Note.md`). Anything else filed as an idea keeps its shape.
    public static func isCaptureBundle(_ folder: URL) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        let visible = names.filter { !$0.hasPrefix(".") }
        guard !visible.isEmpty, visible.allSatisfy({ name in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }) else { return false }
        return names.contains(MobileCaptureBundleReceipt.filename) || visible.contains(bundleNoteName)
    }
}
