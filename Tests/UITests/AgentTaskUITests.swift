import XCTest
import BetterWorkspaceCore

final class AgentTaskUITests: IsolatedUITestCase {
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private var project: URL { Self.workspaceRoot.appendingPathComponent("Projects/Fixture project") }
    private func openProject(width: Int = 820, height: Int = 520) throws -> XCUIApplication {
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        _ = ProjectStore(database: db).register(url: project)
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects", "-bwWindowWidth", String(width), "-bwWindowHeight", String(height)])
        app.launch(); requireWindow(app)
        app.radioButtons["Cards"].firstMatch.click()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture project")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15)); card.click()
        XCTAssertTrue(app.buttons["projects.plan.agent"].firstMatch.waitForExistence(timeout: 10))
        return app
    }
    private func createTask(id: String, title: String = "Create hello.txt") throws -> WorkItem {
        try WorkItemService().create(WorkItem(id: id, kind: .task, title: title, projectPath: "Projects/Fixture project",
            body: "Create hello.txt containing exactly hello followed by a newline.", url: project.appendingPathComponent("placeholder")),
            in: Self.workspaceRoot.appendingPathComponent("To Do"))
    }
    private func stage(task: WorkItem, provider: String, receipt: Data? = nil, runID: String = UUID().uuidString) throws -> URL {
        let folder = Self.fixtureRoot.appendingPathComponent("AgentRuns/\(runID)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let snapshot = AgentTaskSnapshot(id: task.id, title: task.title, body: task.body,
            fingerprint: AgentTaskSnapshot.fingerprint(task), workPath: task.url.canonicalPath)
        let request = AgentTaskRequest(runID: runID, projectPath: project.canonicalPath, provider: provider, model: "fixture",
            effort: "", endpoint: "", sequential: true, instructions: "Tiny smoke task", tasks: [snapshot])
        try JSONEncoder().encode(request).write(to: folder.appendingPathComponent("request.json"))
        let data = try receipt ?? JSONSerialization.data(withJSONObject: ["runID": runID, "state": "finished", "summary": "Created hello.txt",
            "completed": [["id": task.id, "evidence": "Verified exact hello.txt content"]]])
        try data.write(to: folder.appendingPathComponent("receipt.json"))
        return folder
    }
    private func waitForCompletion(_ tasks: [WorkItem]) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tasks.allSatisfy { (try? String(contentsOf: $0.url).contains("status: completed")) == true }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }
    func testSelectionInstructionsAndOrderingAtMinimumWindow() throws {
        _ = try createTask(id: "one", title: "First tiny task")
        _ = try createTask(id: "two", title: "Second tiny task")
        let app = try openProject()
        app.buttons["projects.plan.agent"].firstMatch.click()
        let first = app.checkBoxes["agentTasks.task.one"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.click()
        app.checkBoxes["agentTasks.task.two"].firstMatch.click()
        let earlier = app.buttons["Move Second tiny task earlier"].firstMatch
        XCTAssertTrue(earlier.isEnabled); earlier.click()
        XCTAssertFalse(app.buttons["Move Second tiny task earlier"].firstMatch.isEnabled)
        app.checkBoxes["agentTasks.sequential"].firstMatch.click()
        XCTAssertFalse(app.buttons["Move Second tiny task earlier"].firstMatch.exists)
        let text = app.textViews["agentTasks.instructions"].firstMatch
        text.click(); text.typeText("Do the tiny tasks only.")
        XCTAssertTrue(app.buttons["agentTasks.submit"].firstMatch.isEnabled)
        shoot(app, "agent-tasks-820x520")
    }
    func testCompletionReceiptsApplyForAllProvidersAndPersist() throws {
        let tasks = try ["claude", "codex", "antigravity", "lmstudio"].map { provider -> WorkItem in
            let task = try createTask(id: "smoke-\(provider)", title: "\(provider) tiny task")
            _ = try stage(task: task, provider: provider)
            return task
        }
        let app = try openProject(width: 1200, height: 900)
        waitForCompletion(tasks)
        app.buttons["projects.plan.agent"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Runs and completion evidence"].firstMatch.waitForExistence(timeout: 5))
        shoot(app, "agent-tasks-completion-receipts")
        app.terminate(); app.launch(); requireWindow(app)
        waitForCompletion(tasks)
        for task in tasks {
            XCTAssertEqual(WorkItemService().read(at: task.url)?.status, .completed)
        }
    }
    func testChangedTaskAndInvalidReceiptAreNotCompleted() throws {
        let changed = try createTask(id: "changed")
        _ = try stage(task: changed, provider: "codex")
        var edit = changed; edit.body = "Changed requirements"
        _ = try WorkItemService().update(edit)
        let foreign = try createTask(id: "foreign")
        let runID = UUID().uuidString
        let bad = try JSONSerialization.data(withJSONObject: ["runID": runID, "state": "finished", "summary": "Untrusted", "completed": [["id": "not-selected", "evidence": "claim"]]])
        let folder = try stage(task: foreign, provider: "claude", receipt: bad, runID: runID)
        let app = try openProject()
        let ack = folder.appendingPathComponent("ack.json")
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: ack.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
        XCTAssertEqual(WorkItemService().read(at: changed.url)?.status, .open)
        XCTAssertEqual(WorkItemService().read(at: foreign.url)?.status, .open)
        app.terminate()
    }
    func testGraphCompletionStaysLocalWithoutChangingNotionBaseline() throws {
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = try ProjectGraphStore(database: db)
        let source = ProjectGraphSource(id: "tasks", title: "Tasks", kind: .tasks, schema: ProjectJSON([
            "Title": ["id": "title", "type": "title"], "complete": ["id": "done", "type": "checkbox"]]))
        try store.write("sources", [source])
        var record = ProjectGraphRecord(id: "graph-task", pageID: "remote-task-page", sourceID: source.id, kind: .tasks)
        record.set("Title", value: .string("Graph task"), source: source)
        record.set("complete", value: .bool(false), source: source)
        record.baseline = record.local; record.remote = record.local
        try store.save(record)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let snapshot = AgentTaskSnapshot(id: record.id, title: record.title, body: "", fingerprint: AgentTaskSnapshot.digest(try encoder.encode(record)), workPath: nil)
        let request = AgentTaskRequest(projectPath: project.canonicalPath, provider: "codex", model: "fixture", effort: "", endpoint: "", sequential: true, instructions: "", tasks: [snapshot])
        let folder = Self.fixtureRoot.appendingPathComponent("AgentRuns/\(request.runID)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(request).write(to: folder.appendingPathComponent("request.json"))
        try JSONSerialization.data(withJSONObject: ["runID": request.runID, "state": "finished", "summary": "Done", "completed": [["id": record.id, "evidence": "Verified work"]]])
            .write(to: folder.appendingPathComponent("receipt.json"))
        let app = try openProject()
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? store.record(id: record.id))?.value("complete", source: source)["checkbox"].bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
        let saved = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(saved.baseline, record.baseline)
        XCTAssertEqual(saved.remote, record.remote)
        app.terminate()
    }

    /// Optional: consume this run's real CLI smoke receipts without spending credits again.
    func testLiveSmokeReceiptsCompleteBetterWorkspaceTasks() throws {
        guard let path = ProcessInfo.processInfo.environment["BW_AGENT_SMOKE_RESULTS"] else { throw XCTSkip("Run Tools/agent_tasks_smoke.py and pass BW_AGENT_SMOKE_RESULTS to validate real provider receipts.") }
        let results = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
        var tasks: [WorkItem] = []
        for result in results where result["passed"] as? Bool == true {
            let provider = result["provider"] as! String
            let folder = URL(fileURLWithPath: result["folder"] as! String)
            let receiptData = try Data(contentsOf: folder.appendingPathComponent("receipt.json"))
            let receipt = try JSONDecoder().decode(AgentTaskReceipt.self, from: receiptData)
            let task = try createTask(id: "smoke-\(provider)")
            _ = try stage(task: task, provider: provider, receipt: receiptData, runID: receipt.runID)
            tasks.append(task)
        }
        XCTAssertFalse(tasks.isEmpty)
        let app = try openProject(); waitForCompletion(tasks)
        app.buttons["projects.plan.agent"].firstMatch.click()
        shoot(app, "agent-tasks-real-provider-completions")
    }

    /// Opt-in and credit bounded: the actual sheet submits through Terminal and native polling.
    func testLiveSubmitTerminalCompletesDisposableTask() throws {
        guard let provider = ProcessInfo.processInfo.environment["BW_LIVE_AGENT_SMOKE"],
              ["claude", "codex", "antigravity", "lmstudio"].contains(provider) else {
            throw XCTSkip("Set TEST_RUNNER_BW_LIVE_AGENT_SMOKE to explicitly authorize one tiny live provider task.")
        }
        let models = ["claude": "haiku", "codex": "gpt-6-luna", "antigravity": "gemini-3.8-flash-low",
                      "lmstudio": ProcessInfo.processInfo.environment["BW_SMOKE_LOCAL_MODEL"] ?? "qwen/qwen3.5-9b"]
        var task = try createTask(id: "live-smoke-\(provider)")
        if provider == "codex" {
            task.body = "Run curl --fail --silent --show-error --max-time 15 https://registry.npmjs.org/next/latest -o npm-check.json. Verify this JSON has a name field equal to next. Then create hello.txt containing exactly hello followed by a newline. Do not install packages or read any other directory. Verify hello.txt and report completion only if both checks pass."
        } else if provider == "antigravity" {
            task.body = "Create hello.txt containing exactly hello followed by a newline. Then verify it by running the command: /usr/bin/printf 'hello\\n' | /usr/bin/cmp - hello.txt. Ask for the specific command approval in Terminal when needed. Report completion only if the command succeeds. Do not inspect any other directory."
        }
        task = try WorkItemService().update(task)
        for name in ["AGENTS.md", "CLAUDE.md"] {
            try "Only perform the tiny selected task. Do not install anything, delegate, or inspect other directories. Return verified completion.\n".write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        _ = ProjectStore(database: db).register(url: project)
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects"])
        app.launchEnvironment["BW_LIVE_AGENT_SMOKE"] = provider
        app.launch(); requireWindow(app)
        app.radioButtons["Cards"].firstMatch.click()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture project")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15)); card.click()
        app.buttons["projects.plan.agent"].firstMatch.click()
        let check = app.checkBoxes["agentTasks.task.\(task.id)"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 10)); check.click()
        app.sheets.firstMatch.scrollViews.firstMatch.swipeUp()
        let providers = app.popUpButtons["agentTasks.provider"].firstMatch
        providers.click()
        let names = ["claude": "Claude", "codex": "Codex", "antigravity": "Antigravity", "lmstudio": "LM Studio"]
        let option = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", names[provider]!)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10)); option.click()
        app.sheets.firstMatch.scrollViews.firstMatch.swipeUp()
        let exact = app.textFields["Exact model ID (optional)"].firstMatch
        exact.click(); exact.typeText(models[provider]!)
        if provider == "codex" { app.checkBoxes["agentTasks.network"].firstMatch.click() }
        let submit = app.buttons["agentTasks.submit"].firstMatch
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: submit)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 40), .completed)
        print("LIVE SMOKE fixture: \(Self.fixtureRoot.path) provider: \(provider)")
        submit.click()
        let runsRoot = Self.fixtureRoot.appendingPathComponent("AgentRuns")
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if WorkItemService().read(at: task.url)?.status == .completed { return true }
            let folders = (try? FileManager.default.contentsOfDirectory(at: runsRoot, includingPropertiesForKeys: nil)) ?? []
            return folders.contains { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("receipt.json")),
                      let receipt = try? JSONDecoder().decode(AgentTaskReceipt.self, from: data) else { return false }
                return ["blocked", "failed"].contains(receipt.state)
            }
        }, object: nil)
        let waitResult = XCTWaiter.wait(for: [done], timeout: provider == "lmstudio" ? 360 : 240)
        let folders = try FileManager.default.contentsOfDirectory(at: Self.fixtureRoot.appendingPathComponent("AgentRuns"), includingPropertiesForKeys: nil)
        for folder in folders {
            for name in ["request.json", "receipt.json", "ack.json", "output-0.log", "error-0.log", "interactive-0.log"] {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) {
                    let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.plain-text")
                    evidence.name = "live-\(provider)-\(name)"; evidence.lifetime = .keepAlways; add(evidence)
                }
            }
        }
        XCTAssertEqual(waitResult, .completed)
        XCTAssertEqual(WorkItemService().read(at: task.url)?.status, .completed, "Inspect retained live receipt and provider logs for the blocker")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("hello.txt")), "hello\n")
        if provider == "codex" {
            let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: project.appendingPathComponent("npm-check.json"))) as! [String: Any]
            XCTAssertEqual(payload["name"] as? String, "next")
        }
        app.activate(); shoot(app, "agent-tasks-live-submit-\(provider)")
        app.terminate(); app.launch(); requireWindow(app)
        XCTAssertEqual(WorkItemService().read(at: task.url)?.status, .completed)
    }
}
