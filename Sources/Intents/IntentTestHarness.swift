#if DEBUG
import AppIntents
import Foundation

/// `-BWTestRunIntent <spec>` (DEBUG only): runs one of the capture intents in-process,
/// with its parameters set, through the same `capture()` that its `perform()` calls —
/// no logic of its own. UI tests use it because they cannot drive Siri or Shortcuts.
///
/// Specs: `quick|text`, `idea|text`, `folder|<folder>|text`, `tags|<a,b>|text`.
/// Folders and tag names resolve through the intents' own entity queries, as typed
/// values do in Shortcuts.
@MainActor
enum IntentTestHarness {
    static let defaultsKey = "BWTestRunIntent"

    static var requestedSpec: String? { UserDefaults.standard.string(forKey: defaultsKey) }

    static func run(_ spec: String) async -> String {
        let parts = spec.components(separatedBy: "|")
        do {
            switch parts.first {
            case "quick" where parts.count == 2:
                var intent = QuickCaptureIntent()
                intent.text = parts[1]
                return try await intent.capture()
            case "idea" where parts.count == 2:
                var intent = CaptureIdeaIntent()
                intent.text = parts[1]
                return try await intent.capture()
            case "folder" where parts.count == 3:
                guard let folder = try await CaptureDestinationQuery().entities(matching: parts[1]).first else {
                    return "Intent test: no folder \(parts[1])"
                }
                var intent = CaptureToFolderIntent()
                intent.text = parts[2]
                intent.folder = folder
                return try await intent.capture()
            case "tags" where parts.count == 3:
                var tags: [CaptureTagEntity] = []
                for name in parts[1].components(separatedBy: ",") {
                    if let best = try await CaptureTagQuery().entities(matching: name).first { tags.append(best) }
                }
                var intent = QuickCaptureIntent()
                intent.text = parts[2]
                intent.tags = tags
                return try await intent.capture()
            default:
                return "Intent test: unknown spec \(spec)"
            }
        } catch {
            return "Intent test failed: \(error.localizedDescription)"
        }
    }
}
#endif
