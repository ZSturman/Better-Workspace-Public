import XCTest
@testable import BetterWorkspaceCore

/// The service's payloads, as it actually sends them (shapes copied from live responses
/// and from `session_telemetry_v2.py`). A field this app misreads is a silent gap in
/// the screen, so each one that is shown is checked here.
final class BackgroundServiceClientTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testAnActiveSessionNamesItsProjectAndHowLongItHasRun() throws {
        let live = try BackgroundServiceClient.decodeLiveSession(data("""
        {"schema_version": 1, "data": {"active": true,
          "session": {"id": "s1", "started_at": "2026-10-01T00:47:18.485187+00:00", "open_reason": "activity",
                      "meaningful_event_count": 4, "active_seconds": 300.5, "burst_count": 2},
          "project": {"id": "p1", "name": "Better Workspace"},
          "elapsed_seconds": 1385, "goals": [], "recent_files": ["Projects/Better Workspace/README.md"],
          "commits": [], "recent_context": [], "recent_notifications": []}}
        """))
        XCTAssertEqual(live?.projectName, "Better Workspace")
        XCTAssertEqual(live?.projectID, "p1")
        XCTAssertEqual(live?.sessionID, "s1")
        XCTAssertEqual(live?.elapsedSeconds, 1385)
        XCTAssertNotNil(live?.startedAt)
        XCTAssertEqual(live?.recentFiles, ["Projects/Better Workspace/README.md"])
    }

    func testNoSessionInProgressIsNilNotAFailure() throws {
        let live = try BackgroundServiceClient.decodeLiveSession(data("""
        {"schema_version": 1, "data": {"active": false, "session": null, "project": null, "elapsed_seconds": 0,
          "goals": [], "recent_files": [], "recent_context": [], "recent_notifications": [], "commits": []}}
        """))
        XCTAssertNil(live)
    }

    func testIdeaMetadataKeepsWhatWasSetAndLeavesBlanksBlank() throws {
        let ideas = try BackgroundServiceClient.decodeIdeas(data("""
        {"schema_version": 1, "data": [
          {"id": "i1", "title": "Amy", "path": "/W/Ideas/Amy", "type": "concept", "status": "exploring",
           "one_liner": "", "tags": [], "domains": [], "tools": [], "mediums": [], "related_projects": [],
           "potential_projects": [], "impact": "Medium", "effort": null, "confidence": null, "keep_suggesting": true,
           "defer_until": null, "last_score": 0.2, "last_surfaced_at": null},
          {"id": "i2", "title": "Two", "path": "/W/Ideas/Two", "effort": 3, "keep_suggesting": false}
        ]}
        """))
        XCTAssertEqual(ideas.count, 2)
        XCTAssertEqual(ideas[0].status, "exploring")
        XCTAssertEqual(ideas[0].type, "concept")
        XCTAssertEqual(ideas[0].impact, "Medium")
        XCTAssertNil(ideas[0].oneLiner, "An empty one-liner is no one-liner")
        XCTAssertEqual(ideas[0].lastScore, 0.2)
        XCTAssertEqual(ideas[1].effort, "3", "Effort has been stored as a number too")
        XCTAssertFalse(ideas[1].keepSuggesting)
    }

    func testWorkLogDraftsUnpackTheirPayloadNewestDayFirst() throws {
        let payload = #"{\"active_minutes\": 4.2, \"elapsed_minutes\": 12.2, \"session_count\": 2, \"files\": [\"Projects/A/x.swift\"]}"#
        let logs = try BackgroundServiceClient.decodeWorkLogs(data("""
        {"schema_version": 1, "data": [
          {"id": "w1", "project_id": "p1", "project_name": "A", "date_key": "2026-09-29", "session_ids_json": "[]",
           "payload_json": "\(payload)", "status": "prepared", "notion_page_id": null, "sync_error": null,
           "created_at": "x", "updated_at": "x"},
          {"id": "w2", "project_id": "p2", "project_name": "B", "date_key": "2026-09-30", "session_ids_json": "[]",
           "payload_json": null, "status": "synced", "notion_page_id": "abc", "sync_error": null,
           "created_at": "x", "updated_at": "x"}
        ]}
        """))
        XCTAssertEqual(logs.map(\.id), ["w2", "w1"])
        XCTAssertEqual(logs[1].activeMinutes, 4.2)
        XCTAssertEqual(logs[1].sessionCount, 2)
        XCTAssertEqual(logs[1].files, ["Projects/A/x.swift"])
        XCTAssertFalse(logs[1].syncedToNotion)
        XCTAssertTrue(logs[0].syncedToNotion)
        XCTAssertFalse(logs[1].isReconstructed, "A draft without the count was observed live")
    }

    /// Backfilled history says what it is, and a day nothing survives for is reported,
    /// not left out.
    func testReconstructedDraftsAndDayCoverageAreTold() throws {
        let partly = #"{\"session_count\": 3, \"backfilled_session_count\": 1}"#
        let wholly = #"{\"session_count\": 2, \"backfilled_session_count\": 2}"#
        let logs = try BackgroundServiceClient.decodeWorkLogs(data("""
        {"schema_version": 1, "data": [
          {"id": "w1", "project_id": "p1", "project_name": "A", "date_key": "2026-09-21",
           "payload_json": "\(partly)", "status": "prepared", "notion_page_id": null},
          {"id": "w2", "project_id": "p2", "project_name": "B", "date_key": "2026-09-16",
           "payload_json": "\(wholly)", "status": "backfilled", "notion_page_id": null}
        ]}
        """))
        XCTAssertEqual(logs.map(\.reconstructedSessionCount), [1, 2])
        XCTAssertTrue(logs[0].isReconstructed)
        XCTAssertFalse(logs[0].isWhollyReconstructed)
        XCTAssertTrue(logs[1].isWhollyReconstructed)

        let coverage = try BackgroundServiceClient.decodeWorkLogCoverage(data("""
        {"schema_version": 1, "data": {"ran_at": "x", "days": {
          "2026-09-15": {"status": "no_evidence", "filesystem_events": 0, "terminal_events": 0, "reconstructed_sessions": 0},
          "2026-09-16": {"status": "reconstructed", "filesystem_events": 5142, "terminal_events": 62, "reconstructed_sessions": 5},
          "2026-09-17": {"status": "something_new"}
        }}}
        """))
        XCTAssertEqual(coverage["2026-09-15"]?.status, .noEvidence)
        XCTAssertEqual(coverage["2026-09-16"]?.evidenceCount, 5204)
        XCTAssertEqual(coverage["2026-09-16"]?.reconstructedSessions, 5)
        XCTAssertEqual(coverage["2026-09-17"]?.status, .unknown, "An unfamiliar status is not a crash")
        XCTAssertEqual(try BackgroundServiceClient.decodeWorkLogCoverage(data(#"{"schema_version": 1, "data": {"days": {}}}"#)).count, 0)
    }

    func testOnlySuggestionsNobodyHasActedOnAreOpen() throws {
        let notifications = try BackgroundServiceClient.decodeNotifications(data("""
        {"schema_version": 1, "data": [
          {"id": "n1", "type": "suggestion", "title": "Idea A", "body": "Resurfaced", "entity_id": "i1",
           "state": "delivered", "selected_action": null, "created_at": "2026-09-22T23:35:55.287967+00:00"},
          {"id": "n2", "type": "suggestion", "title": "Idea B", "body": null, "entity_id": "i2",
           "state": "acted", "selected_action": "not_related", "created_at": "2026-09-23T00:00:00+00:00"},
          {"id": "n3", "type": "idea_sync_conflict", "title": "Conflict", "body": null, "entity_id": null,
           "state": "delivered", "selected_action": null, "created_at": "2026-09-21T00:00:00+00:00"}
        ]}
        """))
        XCTAssertEqual(notifications.map(\.id), ["n2", "n1", "n3"], "Newest first")
        XCTAssertEqual(notifications.filter(\.isOpenSuggestion).map(\.id), ["n1"])
    }

    func testAnUnreachableServiceReadsAsUnknownNotEmpty() async {
        // Nothing listens on this port; every read must answer "could not read".
        let nowhere = URL(string: "http://127.0.0.1:9")!
        let client = BackgroundServiceClient()
        let ideas = await client.ideas(baseURL: nowhere, timeout: 1)
        let logs = await client.workLogs(baseURL: nowhere, timeout: 1)
        let live = await client.liveSession(baseURL: nowhere, timeout: 1)
        let health = await client.health(baseURL: nowhere, timeout: 1)
        XCTAssertNil(ideas)
        XCTAssertNil(logs)
        XCTAssertNil(live as Any?)
        XCTAssertNil(health)
    }

    func testTheNotionConfigurationIsReadWithoutTheToken() throws {
        let status = try BackgroundServiceClient.decodeNotionStatus(data("""
        {"schema_version": 1, "data": {"notion_enabled": true, "ideas_notion_sync_enabled": true,
          "ideas_notion_sync_default": false,
          "notion": {"token_present": true,
            "databases": {"projects": "304aec94-a", "work_log": "304aec94-b", "ideas": "304aec94-c"},
            "projects_cache_health": {"state": "ok"},
            "ideas_sync_health": {"state": "database_missing", "error": "Notion HTTP 404"},
            "ideas_sync_paused_until": "2026-10-01T11:00:00+00:00",
            "work_logs_enabled": true, "work_logs_notion_sync": false, "work_logs_authoritative_writer": "legacy"}}}
        """))
        XCTAssertTrue(status.tokenPresent)
        XCTAssertEqual(status.ideasDatabaseID, "304aec94-c")
        XCTAssertTrue(status.ideasSyncEnabled)
        XCTAssertEqual(status.ideasSyncHealth?.state, "database_missing")
        XCTAssertNotNil(status.ideasSyncPausedUntil)
        XCTAssertFalse(status.workLogSyncEnabled)
    }

    func testAServiceFromBeforeTheNotionBlockStillDecodes() throws {
        let status = try BackgroundServiceClient.decodeNotionStatus(data("""
        {"schema_version": 1, "data": {"notion_enabled": false, "ideas_notion_sync_enabled": false, "ideas_notion_sync_default": false}}
        """))
        XCTAssertFalse(status.enabled)
        XCTAssertNil(status.ideasDatabaseID)
    }

    func testDurationsReadAtAGlance() {
        XCTAssertEqual(Format.duration(seconds: 59), "1m")
        XCTAssertEqual(Format.duration(seconds: 42 * 60), "42m")
        XCTAssertEqual(Format.duration(seconds: 65 * 60), "1h 05m")
    }
}

/// Moving the service out of the Workspace Watcher checkout must keep every setting it
/// ran with, and must not leave the Notion token path pointing into code that each
/// install replaces.
final class BackgroundServiceLayoutTests: XCTestCase {

    private let layout = BackgroundServiceLayout(home: URL(fileURLWithPath: "/Users/x/Library/Application Support/BetterWorkspace/BackgroundService"))

    func testTheOldConfigCarriesOverWithOnlyTheTokenFileRepointed() {
        let legacy = """
        [workspace_watcher]
        workspace_root = "/Users/x/Workspace"

        [workspace_watcher.intent_folders.declared]
        "Ideas" = "Ideas" # renamed 2026-09-28

        [workspace_watcher.notion]
        enabled = true
        env_file = ".env"
        token_env = "NOTION_API_KEY"

        [notion]
          env_file = '.env'   # v1
        [other]
        env_file = "/absolute/elsewhere.env"
        """
        let migrated = layout.migratedConfig(from: legacy)
        XCTAssertTrue(migrated.contains(#"workspace_root = "/Users/x/Workspace""#))
        XCTAssertTrue(migrated.contains(#""Ideas" = "Ideas" # renamed 2026-09-28"#), "Comments survive")
        XCTAssertTrue(migrated.contains(#"token_env = "NOTION_API_KEY""#))
        let expected = #"env_file = "\#(layout.environment.path)""#
        XCTAssertEqual(migrated.components(separatedBy: expected).count - 1, 2, "Both relative env_file lines")
        XCTAssertTrue(migrated.contains(#"  env_file = "\#(layout.environment.path)""#), "Indentation kept")
        XCTAssertTrue(migrated.contains(#"env_file = "/absolute/elsewhere.env""#), "An absolute path is left alone")
        XCTAssertFalse(migrated.contains(#"env_file = ".env""#))
    }

    func testRetiredSettingsThatPointOutsideBetterWorkspaceAreDropped() {
        let legacy = """
        [workspace_watcher.notion]
        enabled = true
        client_source = "Projects/Task Management/src"
        timeout_seconds = 30.0

        # Describes the retired table, so it goes with it.
        #
        # (still describing it)
        [external_task_sync]
        enabled = true
        client_source = "Projects/Task Management/src"

        # Fragmentation: introduces the next table and must survive.
        [fragmentation]
        enabled = true
        """
        let migrated = layout.migratedConfig(from: legacy)
        XCTAssertFalse(migrated.contains("Task Management"))
        XCTAssertFalse(migrated.contains("[external_task_sync]"))
        XCTAssertFalse(migrated.contains("retired table"))
        XCTAssertFalse(migrated.contains("still describing"))
        XCTAssertTrue(migrated.contains("timeout_seconds = 30.0"))
        XCTAssertTrue(migrated.contains("# Fragmentation: introduces the next table and must survive.\n[fragmentation]\nenabled = true"))
    }

    func testAFreshConfigCarriesTheSettingsThisAppReliesOn() {
        let fresh = layout.freshConfig(workspaceRoot: URL(fileURLWithPath: "/Users/x/Workspace"))
        XCTAssertTrue(fresh.contains(#""Ideas" = "Ideas""#))
        XCTAssertTrue(fresh.contains("write_documents = false"))
        XCTAssertTrue(fresh.contains(#"workspace_root = "/Users/x/Workspace""#))
    }

    func testInstalledPathsStayInsideItsOwnFolder() {
        for url in [layout.code, layout.launcher, layout.python, layout.config, layout.rules, layout.environment] {
            XCTAssertTrue(url.path.hasPrefix(layout.home.path + "/"), url.path)
        }
    }
}

/// Editing an idea sends only what a person changed, in the service's field names.
final class IdeaChangesTests: XCTestCase {

    private let idea = IdeaRecord(id: "i1", title: "Amy", path: "/W/Ideas/Amy", type: "concept", status: "exploring",
                                  oneLiner: nil, impact: "Medium", effort: nil, tags: [], relatedProjects: [],
                                  keepSuggesting: true, deferUntil: nil, lastScore: nil, lastSurfacedAt: nil)

    func testOnlyWhatChangedIsSent() {
        let unchanged = IdeaChanges.between(idea, status: "exploring", type: "concept", impact: "Medium",
                                            oneLiner: "", keepSuggesting: true)
        XCTAssertTrue(unchanged.isEmpty)

        let edited = IdeaChanges.between(idea, status: " plan ", type: "concept", impact: "",
                                         oneLiner: "A short line", keepSuggesting: false)
        XCTAssertEqual(edited.body["status"] as? String, "plan")
        XCTAssertEqual(edited.body["impact"] as? String, "", "Clearing a value is a change")
        XCTAssertEqual(edited.body["one_liner"] as? String, "A short line")
        XCTAssertEqual(edited.body["keep_suggesting"] as? Bool, false)
        XCTAssertNil(edited.body["type"])
    }

    func testChoicesOfferSuggestionsThenWhatIsInUseOnce() {
        let choices = IdeaChanges.choices(suggested: ["raw", "plan"], inUse: ["to_write", nil, "Plan", "article"])
        XCTAssertEqual(choices, ["raw", "plan", "article", "to_write"])
    }

    func testTheServicesAnswerToAnEditDecodes() throws {
        let updated = try BackgroundServiceClient.decodeIdea(Data("""
        {"schema_version": 1, "data": {"id": "i1", "title": "Amy", "path": "/W/Ideas/Amy", "type": "concept",
         "status": "plan", "one_liner": "A short line", "impact": "", "keep_suggesting": false, "tags": []}}
        """.utf8))
        XCTAssertEqual(updated.status, "plan")
        XCTAssertNil(updated.impact)
        XCTAssertFalse(updated.keepSuggesting)
    }
}
