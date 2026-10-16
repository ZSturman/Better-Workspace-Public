import AppIntents
import Foundation
import BetterWorkspaceCore

// The capture actions Shortcuts, Siri, Spotlight and the Action Button see.
//
// Shared by the Mac and iPhone/iPad apps. Each app supplies `PlatformCaptureBackend`,
// which saves through that platform's existing capture path: on the Mac the Ingest
// service (filed immediately when a folder is chosen); on the phone the shared iCloud
// Inbox plus a queued filing request the Mac applies when it syncs. A small set that
// composes: text, an idea, a folder, the clipboard, files — each with optional tags.

/// What a platform hands the shared intents.
struct CaptureIntentRequest {
    var text: String?
    var title: String?
    var link: String?
    var files: [(data: Data, filename: String)] = []
    var destinationID: String?
    var asIdea = false
    var tags: [CaptureTagEntity] = []
}

// MARK: - Entities

/// A top-level Workspace folder a capture can be filed into.
struct CaptureDestinationEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Workspace Folder"
    static var defaultQuery = CaptureDestinationQuery()

    /// The folder's workspace-relative path, which is also its name.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "folder"))
    }
}

struct CaptureDestinationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CaptureDestinationEntity] {
        await PlatformCaptureBackend.destinations().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CaptureDestinationEntity] {
        await PlatformCaptureBackend.destinations()
    }

    func entities(matching string: String) async throws -> [CaptureDestinationEntity] {
        let query = TagMatching.normalized(string)
        return await PlatformCaptureBackend.destinations().filter {
            query.isEmpty || TagMatching.normalized($0.name).contains(query)
        }
    }
}

/// A tag. Typing a name that matches nothing offers it as a new tag
/// (`id` prefixed `new:`), which is created when the capture is saved.
struct CaptureTagEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tag"
    static var defaultQuery = CaptureTagQuery()
    static let newPrefix = "new:"

    let id: String
    let name: String

    var isNew: Bool { id.hasPrefix(Self.newPrefix) }

    static func new(named name: String) -> CaptureTagEntity {
        CaptureTagEntity(id: newPrefix + name, name: name)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: isNew ? "New tag “\(name)”" : "\(name)",
                              image: .init(systemName: isNew ? "plus.circle" : "tag"))
    }
}

struct CaptureTagQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CaptureTagEntity] {
        let known = await PlatformCaptureBackend.tags()
        return identifiers.compactMap { id in
            if id.hasPrefix(CaptureTagEntity.newPrefix) {
                return CaptureTagEntity.new(named: String(id.dropFirst(CaptureTagEntity.newPrefix.count)))
            }
            return known.first { $0.id == id }
        }
    }

    func suggestedEntities() async throws -> [CaptureTagEntity] {
        await PlatformCaptureBackend.tags()
    }

    /// The same ranking as typing in the app (`TagMatching`): existing tags first,
    /// and a new tag offered only when nothing has the same name.
    func entities(matching string: String) async throws -> [CaptureTagEntity] {
        let known = await PlatformCaptureBackend.tags()
        let tags = known.map { Tag(id: $0.id, name: $0.name) }
        var result = TagMatching.ranked(string, in: tags).map { CaptureTagEntity(id: $0.id, name: $0.name) }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false, TagMatching.equivalent(to: trimmed, in: tags) == nil {
            result.append(.new(named: trimmed))
        }
        return result
    }
}

// MARK: - Intents

struct QuickCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Capture"
    static var description = IntentDescription(
        "Saves text to your Better Workspace Inbox right away, optionally with tags. Filing can wait.",
        categoryName: "Capture")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What do you want to capture?")
    var text: String

    @Parameter(title: "Tags")
    var tags: [CaptureTagEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$text) in the Inbox") { \.$tags }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let message = try await capture()
        return .result(value: message, dialog: "\(message)")
    }

    /// The whole action; `perform()` only wraps its message for Shortcuts.
    @MainActor
    func capture() async throws -> String {
        try await PlatformCaptureBackend.capture(CaptureIntentRequest(text: text, tags: tags ?? []))
    }
}

struct CaptureIdeaIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Idea"
    static var description = IntentDescription(
        "Records an idea. It becomes its own folder in Ideas.", categoryName: "Capture")

    @Parameter(title: "Idea", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What's the idea?")
    var text: String

    @Parameter(title: "Tags")
    var tags: [CaptureTagEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture idea \(\.$text)") { \.$tags }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let message = try await capture()
        return .result(value: message, dialog: "\(message)")
    }

    @MainActor
    func capture() async throws -> String {
        try await PlatformCaptureBackend.capture(CaptureIntentRequest(text: text, asIdea: true, tags: tags ?? []))
    }
}

struct CaptureToFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Folder"
    static var description = IntentDescription(
        "Captures text straight into a Workspace folder, such as To Read or For Reference.",
        categoryName: "Capture")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What do you want to capture?")
    var text: String

    @Parameter(title: "Folder", requestValueDialog: "Which folder?")
    var folder: CaptureDestinationEntity

    @Parameter(title: "Tags")
    var tags: [CaptureTagEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$folder)") { \.$tags }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let message = try await capture()
        return .result(value: message, dialog: "\(message)")
    }

    @MainActor
    func capture() async throws -> String {
        try await PlatformCaptureBackend.capture(
            CaptureIntentRequest(text: text, destinationID: folder.id, tags: tags ?? []))
    }
}

struct CaptureClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Clipboard"
    static var description = IntentDescription(
        "Saves whatever is on the clipboard — text, a link or an image — to the Inbox or a folder.",
        categoryName: "Capture")

    @Parameter(title: "Folder")
    var folder: CaptureDestinationEntity?

    @Parameter(title: "Tags")
    var tags: [CaptureTagEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture the clipboard") { \.$folder; \.$tags }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let message = try await capture()
        return .result(value: message, dialog: "\(message)")
    }

    @MainActor
    func capture() async throws -> String {
        guard var request = await PlatformCaptureBackend.clipboardRequest() else {
            throw CaptureIntentError.emptyClipboard
        }
        request.destinationID = folder?.id
        request.tags = tags ?? []
        return try await PlatformCaptureBackend.capture(request)
    }
}

struct CaptureFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Files"
    static var description = IntentDescription(
        "Saves files, photos or anything shared to it — use it after “Receive from Share Sheet”.",
        categoryName: "Capture")

    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(title: "Title")
    var title: String?

    @Parameter(title: "Folder")
    var folder: CaptureDestinationEntity?

    @Parameter(title: "Tags")
    var tags: [CaptureTagEntity]?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$files)") { \.$title; \.$folder; \.$tags }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let message = try await capture()
        return .result(value: message, dialog: "\(message)")
    }

    @MainActor
    func capture() async throws -> String {
        let payload = files.map { file in
            (data: file.data, filename: file.filename.isEmpty ? "Shared file" : file.filename)
        }
        guard payload.isEmpty == false else { throw CaptureIntentError.nothingToCapture }
        return try await PlatformCaptureBackend.capture(
            CaptureIntentRequest(title: title, files: payload, destinationID: folder?.id, tags: tags ?? []))
    }
}

enum CaptureIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyClipboard
    case nothingToCapture
    case unknownFolder

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyClipboard:
            return "The clipboard is empty, or Better Workspace was not allowed to paste. In Shortcuts, “Get Clipboard” → “Quick Capture” always works."
        case .nothingToCapture: return "There was nothing to capture."
        case .unknownFolder: return "That folder is not a Workspace folder any more."
        }
    }
}

// MARK: - Shortcuts, Siri and Spotlight

struct BetterWorkspaceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: QuickCaptureIntent(),
                    phrases: ["Capture in \(.applicationName)",
                              "Quick capture in \(.applicationName)",
                              "Add to my \(.applicationName) Inbox"],
                    shortTitle: "Quick Capture", systemImageName: "tray.and.arrow.down")
        AppShortcut(intent: CaptureIdeaIntent(),
                    phrases: ["Capture an idea in \(.applicationName)",
                              "New idea in \(.applicationName)"],
                    shortTitle: "Capture Idea", systemImageName: "lightbulb")
        AppShortcut(intent: CaptureToFolderIntent(),
                    phrases: ["Add to a folder in \(.applicationName)",
                              "File something in \(.applicationName)"],
                    shortTitle: "Add to Folder", systemImageName: "folder")
        AppShortcut(intent: CaptureClipboardIntent(),
                    phrases: ["Capture my clipboard in \(.applicationName)",
                              "Save the clipboard to \(.applicationName)"],
                    shortTitle: "Capture Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: OpenCaptureIntent(),
                    phrases: ["New capture in \(.applicationName)",
                              "Open \(.applicationName) capture"],
                    shortTitle: "New Capture", systemImageName: "square.and.pencil")
    }
}
