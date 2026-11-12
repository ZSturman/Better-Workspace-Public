import Foundation

/// A bounded read-only projection of service history, carried in the existing
/// project envelope. Service IDs, never project names or file timestamps, join it.
public struct ProjectWorkHistory: Codable, Hashable, Sendable {
    public let logs: [WorkLogEntry]
    public let sessions: [WorkSession]
    public let totalLogs: Int
    public let totalSessions: Int

    public init(serviceID: String?, logs: [WorkLogEntry], sessions: [WorkSession]) {
        let selectedLogs = logs.filter { serviceID != nil && $0.projectID == serviceID }
            .sorted { $0.dateKey == $1.dateKey ? $0.id < $1.id : $0.dateKey > $1.dateKey }
        // Daily drafts retain older session facts even after the recent-session
        // endpoint's window has advanced. Prefer its current session when present.
        var byID: [String: WorkSession] = [:]
        for session in selectedLogs.flatMap({ $0.sessions ?? [] }) + sessions
            where serviceID != nil && session.projectID == serviceID { byID[session.id] = session }
        totalLogs = selectedLogs.count
        totalSessions = byID.count
        self.sessions = Array(byID.values.sorted {
            $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt
        }.prefix(60)).map { session in
            WorkSession(id: session.id, projectID: session.projectID, projectName: session.projectName,
                startedAt: session.startedAt, endedAt: session.endedAt, activeSeconds: session.activeSeconds,
                files: Array(session.interestingFiles.prefix(6)), gitBranch: session.gitBranch.map { String($0.prefix(200)) },
                gitSubject: session.gitSubject.map { String($0.prefix(500)) })
        }
        self.logs = selectedLogs.prefix(30).map { log in
            var copy = WorkLogEntry(id: log.id, projectID: log.projectID, projectName: log.projectName,
                dateKey: log.dateKey, status: log.status, activeMinutes: log.activeMinutes,
                elapsedMinutes: log.elapsedMinutes, sessionCount: log.sessionCount,
                summary: log.summary.map { String($0.prefix(2_000)) }, files: [],
                syncedToNotion: log.syncedToNotion, reconstructedSessionCount: log.reconstructedSessionCount,
                notionPageID: log.notionPageID)
            copy.sessionIDs = Array((log.sessionIDs ?? log.sessions?.map(\.id) ?? []).prefix(100))
            copy.startedAt = log.startedAt; copy.endedAt = log.endedAt
            // Session facts live once in this projection; no raw evidence or paths.
            return copy
        }
    }

    public func sessions(for log: WorkLogEntry) -> [WorkSession] {
        let ids = Set(log.sessionIDs ?? [])
        return sessions.filter { ids.contains($0.id) }
    }
}
