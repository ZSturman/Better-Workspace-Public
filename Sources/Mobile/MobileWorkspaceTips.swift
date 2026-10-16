import SwiftUI
import TipKit

enum MobileWorkspaceTipConfiguration {
    static func configure() {
        do {
            if UserDefaults.standard.bool(forKey: "BWResetTipsForTesting") {
                try Tips.resetDatastore()
            }
            try Tips.configure([.displayFrequency(.immediate)])
        } catch {
            #if DEBUG
            print("TipKit setup failed: \(error.localizedDescription)")
            #endif
        }
    }
}

enum MobileWorkspaceGuidance {
    static let viewedOverview = Tips.Event(id: "mobile-workspace.viewed-overview")
    static let viewedBrowse = Tips.Event(id: "mobile-workspace.viewed-browse")
    static let successfulSync = Tips.Event(id: "mobile-workspace.successful-sync")
    static let viewedTags = Tips.Event(id: "mobile-workspace.viewed-tags")
    static let openedEntry = Tips.Event(id: "mobile-workspace.opened-entry")
    static let viewedWork = Tips.Event(id: "mobile-workspace.viewed-work")

    @Parameter static var hasViewedTags: Bool = false
    @Parameter static var hasOpenedEntry: Bool = false
}

struct MobileOverviewTip: Tip {
    var title: Text { Text("Start with what matters now") }
    var message: Text? { Text("Overview brings the next work item, recent projects, ideas, and analytics status into one mobile-first starting point.") }
    var image: Image? { Image(systemName: "rectangle.3.group") }

    var rules: [Rule] {
        #Rule(MobileWorkspaceGuidance.viewedOverview) { $0.donations.count >= 1 }
    }

    var options: [Option] { [MaxDisplayCount(1)] }
}

struct MobileBrowseTip: Tip {
    var title: Text { Text("The Mac publishes this index") }
    var message: Text? { Text("Browse here is read-only. Your files and their contents stay on the Mac.") }
    var image: Image? { Image(systemName: "icloud.and.arrow.down") }

    var rules: [Rule] {
        #Rule(MobileWorkspaceGuidance.viewedBrowse) { $0.donations.count >= 1 }
        #Rule(MobileWorkspaceGuidance.successfulSync) { $0.donations.count >= 1 }
        #Rule(MobileWorkspaceGuidance.$hasViewedTags) { $0 == false }
    }

    var options: [Option] { [MaxDisplayCount(1)] }
}

struct MobileTagsTip: Tip {
    var title: Text { Text("Filter across the workspace") }
    var message: Text? { Text("Choose one or more tags to narrow the published folders, work, and ideas views.") }
    var image: Image? { Image(systemName: "line.3.horizontal.decrease.circle") }

    var rules: [Rule] {
        #Rule(MobileWorkspaceGuidance.viewedTags) { $0.donations.count >= 1 }
        #Rule(MobileWorkspaceGuidance.$hasOpenedEntry) { $0 == false }
    }

    var options: [Option] { [MaxDisplayCount(1)] }
}

struct MobileTagChangeTip: Tip {
    var title: Text { Text("Tag changes are queued safely") }
    var message: Text? { Text("Your tag change is sent as an intent; the Mac applies it and republishes the current file state.") }
    var image: Image? { Image(systemName: "clock.arrow.circlepath") }

    /// Anchored in the entry detail, which is the only place a tag change is made, so
    /// the context is the gate.
    var rules: [Rule] {
        #Rule(MobileWorkspaceGuidance.openedEntry) { $0.donations.count >= 1 }
    }

    var options: [Option] { [MaxDisplayCount(1)] }
}

struct MobileWorkTip: Tip {
    var title: Text { Text("Start with what is Now") }
    var message: Text? { Text("Work is grouped by status; the Next Work widget favors Now, then Next, before Later.") }
    var image: Image? { Image(systemName: "checklist") }

    var rules: [Rule] {
        #Rule(MobileWorkspaceGuidance.viewedWork) { $0.donations.count >= 1 }
    }

    var options: [Option] { [MaxDisplayCount(1)] }
}

/// Planning edits are saved on the phone and applied by the Mac. Worth saying once, in
/// the editor where it matters, rather than as a footer on every edit.
struct MobilePlanningSyncTip: Tip {
    var title: Text { Text("Saved here first") }
    var message: Text? { Text("Your Mac applies the change when it is online, so you can plan offline.") }
    var image: Image? { Image(systemName: "iphone.and.arrow.forward") }
    var options: [Option] { [MaxDisplayCount(1)] }
}
