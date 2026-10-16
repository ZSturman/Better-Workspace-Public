import XCTest
import SwiftUI
import WidgetKit
@testable import BetterWorkspaceCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class WidgetLayoutTests: XCTestCase {
    @MainActor func testSharedLayoutsRenderWithIsolatedFixture() throws {
        let source = fixture()
        let modes: [DashboardMode] = [.project, .focus, .charts, .tasks, .review, .captures, .attention, .nextWork]
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #if os(iOS)
        families.append(.accessoryRectangular)
        #endif
        for family in families {
            for mode in modes {
                let size = dimensions(family)
                let options = DashboardOptions(mode: mode, destinations: ["Tasks", "To Read"])
                let renderer = ImageRenderer(content: card(source, options, family, size))
                renderer.scale = 1
                XCTAssertNotNil(renderer.cgImage, "\(mode) / \(family) did not render")
            }
        }
        let preview = try XCTUnwrap(source.reviewItems.first)
        let confirmation = WidgetConfirmation(id: UUID(), scope: "fixture", edit: .init(operation: .reviewInbox, title: preview.title,
            inboxReview: .init(item: preview, action: .done)), expiresAt: Date().addingTimeInterval(300))
        let gallery = VStack(alignment: .leading, spacing: 16) {
            Text("Better Workspace · shared widget layouts").font(.title2.bold())
            Text("Isolated sample workspace · medium size · native SwiftUI rendering").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                card(source, .init(mode: .project), .systemMedium, dimensions(.systemMedium))
                card(source, .init(mode: .focus), .systemMedium, dimensions(.systemMedium))
                card(source, .init(mode: .charts), .systemMedium, dimensions(.systemMedium))
            }
            HStack(spacing: 16) {
                card(source, .init(mode: .tasks), .systemMedium, dimensions(.systemMedium))
                card(source, .init(mode: .review), .systemMedium, dimensions(.systemMedium))
                card(source, .init(mode: .captures, destinations: ["Tasks", "To Read"]), .systemMedium, dimensions(.systemMedium))
            }
            HStack(spacing: 16) {
                card(source, .init(mode: .attention), .systemMedium, dimensions(.systemMedium))
                card(source, .init(mode: .review), .systemMedium, dimensions(.systemMedium), confirmation)
                card(source, .init(mode: .nextWork), .systemMedium, dimensions(.systemMedium))
            }
        }.padding(24).background(Color.white).environment(\.colorScheme, .light)
        #if os(macOS)
        let host = NSHostingView(rootView: gallery)
        host.appearance = NSAppearance(named: .aqua)
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let platform = "mac"
        #else
        let host = UIHostingController(rootView: gallery)
        let size = host.sizeThatFits(in: CGSize(width: 1200, height: 2000))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(origin: .zero, size: size)) }
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let image = UIGraphicsImageRenderer(size: size).image { context in host.view.layer.render(in: context.cgContext) }
        let data = try XCTUnwrap(image.pngData())
        let platform = "iphone"
        #endif
        XCTAssertGreaterThan(data.count, 50_000, "The gallery must contain rendered content, not a blank image")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("BW-widget-layouts-\(platform)-\(UUID().uuidString).png")
        try data.write(to: path, options: .atomic)
        print("WIDGET_LAYOUT_SCREENSHOT=\(path.path)")
    }
    @MainActor private func card(_ source: WorkspaceDashboardSnapshot, _ options: DashboardOptions, _ family: WidgetFamily,
                                _ size: CGSize, _ confirmation: WidgetConfirmation? = nil) -> some View {
        #if os(iOS)
        let margin: CGFloat = family == .accessoryRectangular ? 0 : 16
        #else
        let margin: CGFloat = 16
        #endif
        return DashboardWidgetView(entry: .init(date: source.updatedAt, snapshot: source, options: options, records: [], confirmation: confirmation, cursor: 0, error: nil), familyOverride: family)
            .frame(width: size.width - margin * 2, height: size.height - margin * 2).padding(margin)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
    }
    private func dimensions(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: .init(width: 170, height: 170)
        case .systemLarge: .init(width: 364, height: 382)
        case .systemExtraLarge: .init(width: 768, height: 382)
        #if os(iOS)
        case .accessoryRectangular: .init(width: 180, height: 72)
        #endif
        default: .init(width: 364, height: 170)
        }
    }
    private func fixture() -> WorkspaceDashboardSnapshot {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let work = [
            MobileWorkItem(id: "done", path: "Projects/Atlas/Work/Done.bw.md", title: "Capture notes", kind: .task, status: .completed, stage: .next, priority: .medium, projectPath: "Projects/Atlas", revision: 1, modifiedAt: now),
            MobileWorkItem(id: "next", path: "Projects/Atlas/Work/Next.bw.md", title: "Review the launch checklist", kind: .task, status: .open, stage: .next, priority: .high, projectPath: "Projects/Atlas", dueDate: now.addingTimeInterval(-86400), revision: 1, modifiedAt: now),
            MobileWorkItem(id: "later", path: "Projects/Beacon/Work/Later.bw.md", title: "Sketch the project outline", kind: .task, status: .open, stage: .next, priority: .medium, projectPath: "Projects/Beacon", revision: 1, modifiedAt: now)
        ]
        let item = OverviewInboxItem(id: "review", path: "To Read/Design notes.md", title: "Design notes.md", category: "To Read", modified: now, size: 48,
            preview: "A few useful ideas for making the next release easier to review.", fingerprint: "fixture-fingerprint")
        let entries = [
            MobileWorkspaceEntry(path: "Projects/Atlas", parentPath: "Projects", name: "Atlas", isDirectory: true, revision: 1, projectDetails: .init(path: "Projects/Atlas", status: "Active", projectID: "atlas", manualScore: 86, ratingCoverage: 1, lastWorked: now.addingTimeInterval(-3600))),
            MobileWorkspaceEntry(path: "Projects/Beacon", parentPath: "Projects", name: "Beacon", isDirectory: true, revision: 1),
            MobileWorkspaceEntry(path: "Tasks", parentPath: nil, name: "Tasks", isDirectory: true, revision: 1),
            MobileWorkspaceEntry(path: "To Read", parentPath: nil, name: "To Read", isDirectory: true, revision: 1)
        ]
        var source = WorkspaceDashboardSnapshot.make(from: .init(entries: entries, workItems: work,
            fetchedAt: now, overview: .init(focusItems: [], inboxItem: item, inboxCheckedAt: now, reviewItems: [item], reviewCount: 1)))
        source.captures = [.init(name: "Release ideas.md", modified: now)]; source.captureCount = 1; source.captureUpdatedAt = now
        return source
    }
}
