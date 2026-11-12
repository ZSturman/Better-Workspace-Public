import Foundation
import BetterWorkspaceCore

/// Explicit UUID-isolated physical UI fixtures. No real stores, network or indexed
/// files are opened. The actual session delivery/review/editor handle these values.
@MainActor
enum UnifiedWorkspaceAcceptanceSeed {
    private static var started: Set<String> = []
    static func prepare(_ session: WorkspaceSession) async throws {
        if session.isFixture, TestIsolation.launchArgument("BWProjectManagementFixture") == "YES", session.records.isEmpty {
            var portfolio = ProjectPortfolioDetails(githubURL: "https://github.com/example/project", websiteURL: "https://example.com")
            portfolio.customLinks = [.init(label: "App Store", url: "https://apps.apple.com/app/id123")]
            _ = try await session.save(content: .init(kind: .project, title: "Creative project", projectMetadata: .init(domain: "Art", status: "Active", projectType: "Animation, Collection"), projectLinks: portfolio), expectedHeads: [])
            try session.finishWelcome()
        }
        if session.isFixture, TestIsolation.launchArgument("BWUnifiedContentFixture") == "YES", session.records.isEmpty {
            _ = try await session.save(content: .init(kind: .note, title: "Shared note", body: "Phone note"), expectedHeads: [])
            _ = try await session.save(content: .init(kind: .idea, title: "Shared idea", body: "Phone idea"), expectedHeads: [])
            let folder = try await session.save(content: .init(kind: .folder, title: "Shared folder", body: "Folder description"), expectedHeads: [])
            _ = try await session.save(content: .init(kind: .note, title: "Nested note", body: "Nested text", parentID: folder.recordID), expectedHeads: [])
            try session.finishWelcome()
        }
        guard session.isFixture, TestIsolation.launchArgument("BWUnifiedReviewFixture") == "YES", session.records.isEmpty, started.insert(session.directory.canonicalPath).inserted else { return }
        let base = try await session.save(content: .init(kind: .note, title: "Concurrent note", body: "Original version"), expectedHeads: [])
        var remote = try WorkspaceReplica(revisions: [base])
        var remoteContent = base.content; remoteContent.body = "Remote version"
        _ = try remote.save(recordID: base.recordID, content: remoteContent, expectedHeads: [base.id], deviceID: UUID(), origin: .mac)
        _ = try remote.save(content: .init(kind: .note, title: "Same name", body: "Mac unique content"), expectedHeads: [], deviceID: UUID(), origin: .mac)
        var local = base.content; local.body = "Local version"
        _ = try await session.save(recordID: base.recordID, content: local, expectedHeads: [base.id])
        _ = try await session.save(content: .init(kind: .note, title: "Same name", body: "Phone unique content"), expectedHeads: [])
        try await session.receive([.init(deviceID: UUID(), sourceID: remote.workspaceID, name: "Synthetic Mac", platform: "Mac", replica: remote, approvals: [])])
        try session.finishWelcome()
    }
}
