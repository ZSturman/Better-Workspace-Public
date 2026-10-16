import Foundation
import CryptoKit

/// Only this explicitly selected task snapshot is sent to a provider.
public struct AgentTaskSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let fingerprint: String
    public let workPath: String?
    public init(id: String, title: String, body: String, fingerprint: String, workPath: String?) {
        self.id = id; self.title = title; self.body = body; self.fingerprint = fingerprint; self.workPath = workPath
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func fingerprint(_ item: WorkItem) -> String {
        // Include every editable field; a changed task must be reviewed before completion.
        let values: [String] = [item.id, item.title, item.body, item.kind.rawValue, item.status.rawValue,
            item.stage.rawValue, item.priority.rawValue, item.projectPath ?? "", item.parentID ?? "",
            item.notionPageID ?? "", String(item.dueDate?.timeIntervalSince1970 ?? 0),
            String(item.completedAt?.timeIntervalSince1970 ?? 0)]
            + [item.relatedIDs, item.parentIDs, item.dependencyIDs, item.featureIDs, item.milestoneIDs, item.extraFrontMatter]
                .map { $0.joined(separator: "\u{0}") }
        return digest(try! JSONEncoder().encode(values))
    }
}

public struct AgentTaskRequest: Codable, Identifiable, Sendable {
    public var id: String { runID }
    public let runID: String
    public let projectPath: String
    public let provider: String
    public let model: String
    public let effort: String
    public let endpoint: String
    public let sequential: Bool
    public let instructions: String
    public let tasks: [AgentTaskSnapshot]
    public let networkAccess: Bool?
    public let interactive: Bool?
    public init(runID: String = UUID().uuidString, projectPath: String, provider: String, model: String,
                effort: String, endpoint: String, sequential: Bool, instructions: String, tasks: [AgentTaskSnapshot],
                networkAccess: Bool = false, interactive: Bool = true) {
        self.runID = runID; self.projectPath = projectPath; self.provider = provider; self.model = model
        self.effort = effort; self.endpoint = endpoint; self.sequential = sequential; self.instructions = instructions; self.tasks = tasks
        self.networkAccess = networkAccess; self.interactive = interactive
    }
}

public struct AgentTaskReceipt: Codable, Sendable {
    public struct Completion: Codable, Equatable, Sendable { public let id: String; public let evidence: String }
    public let runID: String
    public let state: String
    public let completed: [Completion]
    public let summary: String
    /// Exit success alone is never evidence that every task finished.
    public func validated(for request: AgentTaskRequest) throws -> [Completion] {
        let ids = completed.map(\.id), selected = request.tasks.map(\.id)
        guard runID == request.runID, ["running", "finished", "failed", "blocked"].contains(state),
              Set(ids).count == ids.count, Set(ids).isSubset(of: Set(selected)),
              completed.allSatisfy({ !$0.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              !request.sequential || ids == Array(selected.prefix(ids.count)) else { throw ReceiptError.invalid }
        return completed
    }
    public enum ReceiptError: LocalizedError {
        case invalid
        public var errorDescription: String? { "Agent completion report did not match the submitted tasks or order." }
    }
}
