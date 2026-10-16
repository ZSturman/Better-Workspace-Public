import Foundation

/// Decides which filesystem entries are *other applications' bookkeeping* and should
/// not be shown as Workspace content.
///
/// These files are never read, parsed, used as a data model, or modified by this app.
/// They are filtered from display only, so that an Idea folder whose sole content is
/// `watcher.item.toml` correctly reads as empty.
public enum NoiseFilter {

    /// Exact filenames belonging to other tools that share this Workspace.
    public static let foreignMetadataNames: Set<String> = [
        ".DS_Store",
        ".localized",
        "Icon\r",
        "watcher.item.toml",        // Workspace Watcher
        "Project.betterproject",    // Better Projects
        ".hammerspoon",             // Hammerspoon's private flashcard cache
        "notion-flashcards-cache.json",
        "link-review-state.json",
        "original-link-review-state.json",
    ]

    /// Filename extensions belonging to other tools.
    public static let foreignMetadataExtensions: Set<String> = [
        "betterproject",
    ]

    /// Top-level directories under the workspace root that belong to other tools.
    public static let foreignTopLevelDirectories: Set<String> = [
        ".project-core",
        "_audit",
    ]

    /// True when this entry is another system's artifact rather than user content.
    public static func isForeignMetadata(name: String) -> Bool {
        if foreignMetadataNames.contains(name) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty == false, foreignMetadataExtensions.contains(ext) { return true }
        return false
    }

    /// True when this entry should be hidden from a Workspace listing.
    ///
    /// - Parameter showHidden: when true, ordinary dotfiles are kept, but other
    ///   applications' metadata is still suppressed.
    public static func isHidden(name: String, showHidden: Bool) -> Bool {
        if isForeignMetadata(name: name) { return true }
        if showHidden { return false }
        return name.hasPrefix(".")
    }
}
