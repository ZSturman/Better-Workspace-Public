import SwiftUI
import TipKit

enum IngestTipConfiguration {
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

enum IngestGuidance {
    static let captureScreenViewed = Tips.Event(id: "ingest.capture-screen-viewed")
    static let savedCapture = Tips.Event(id: "ingest.saved-capture")

    @Parameter static var savedAttachment: Bool = false

    static func viewedCaptureScreen() { captureScreenViewed.sendDonation() }
    static func captured() { savedCapture.sendDonation() }
}

struct IngestCaptureBasicsTip: Tip {
    var title: Text { Text("Capture notes and images") }
    var message: Text? { Text("Write Markdown and title each image. Save creates separate files in your shared Inbox, ready to file into a destination.") }
    var image: Image? { Image(systemName: "tray.and.arrow.down") }

    var rules: [Rule] {
        #Rule(IngestGuidance.captureScreenViewed) { $0.donations.count >= 1 }
        #Rule(IngestGuidance.savedCapture) { $0.donations.count == 0 }
    }

    var options: [Option] { [MaxDisplayCount(1)] }
}

struct IngestAttachmentTip: Tip {
    var title: Text { Text("Capture more than notes") }
    var message: Text? { Text("Bring in photos, files, or pasted media without leaving your capture flow.") }
    var image: Image? { Image(systemName: "paperclip") }

    var rules: [Rule] {
        #Rule(IngestGuidance.savedCapture) { $0.donations.count >= 3 }
        #Rule(IngestGuidance.$savedAttachment) { $0 == false }
    }

    var options: [Option] { [MaxDisplayCount(1)] }
}

struct IngestQueueTip: Tip {
    var title: Text { Text("Your Inbox is the handoff") }
    var message: Text? { Text("These captures wait safely here until Better Workspace on the Mac classifies them.") }
    var image: Image? { Image(systemName: "tray.full") }

    /// The one thing every user has to understand, so it is owed to the first capture
    /// rather than to anyone who happens to attach a file.
    var rules: [Rule] {
        #Rule(IngestGuidance.savedCapture) { $0.donations.count >= 1 }
    }

    var options: [Option] { [MaxDisplayCount(1)] }
}
