import XCTest
@testable import BetterWorkspaceCore

final class ProjectToolsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-project-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCapabilityRequiresProjectEvidenceAndDetectsXcode() async throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        let swift = root.appendingPathComponent("swift", isDirectory: true)
        let xcode = root.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xcode.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
        try "struct Demo {}".write(to: swift.appendingPathComponent("Demo.swift"), atomically: true, encoding: .utf8)

        let service = ProjectToolCapabilityService()
        let empty = await service.capability(for: plain)
        let source = await service.capability(for: swift)
        let project = await service.capability(for: xcode)
        XCTAssertFalse(empty.canExplain)
        XCTAssertTrue(source.canExplain)
        XCTAssertFalse(source.canFlowReview)
        XCTAssertTrue(project.canFlowReview)
    }

    func testExplainReadsStaticEvidenceWithoutChangingProject() async throws {
        try "# Demo\nTODO: ship it\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "// FIXME: make safer\nstruct Demo {}".write(to: root.appendingPathComponent("Demo.swift"), atomically: true, encoding: .utf8)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let report = await ProjectExplanationService().analyze(at: root)
        let after = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(report.sourceFileCount, 1)
        XCTAssertTrue(report.languages.contains("Swift"))
        XCTAssertTrue(report.findings.contains { $0.title == "Unfinished-work signals" })
        XCTAssertEqual(before, after, "Normal Explain analysis must not write project files")
    }

    func testVerificationNeverPlansNpmScripts() async throws {
        try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let report = await ProjectExplanationService().analyze(at: root)
        let plan = await ProjectExplanationService().verificationPlan(for: report)
        XCTAssertFalse(plan.commands.contains { $0.command.contains("npm") })
    }

    func testFlowPlanWritesOnlyConfirmedFlowPaths() async throws {
        let project = root.appendingPathComponent("Demo.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("xcshareddata/xcschemes"), withIntermediateDirectories: true)
        try "<Scheme/>".write(to: project.appendingPathComponent("xcshareddata/xcschemes/Demo.xcscheme"), atomically: true, encoding: .utf8)
        let service = FlowReviewService()
        let analysis = await service.analyze(at: root)
        XCTAssertFalse(analysis.configured)
        XCTAssertEqual(analysis.schemes, ["Demo"])
        let plan = await service.configurationPlan(for: analysis, scheme: "Demo")
        XCTAssertEqual(Set(plan.map(\.path)), Set(["flow-review/config.yaml", "flow-review/flows/new-flow.yaml", ".flow-review/generated"]))
        try await service.apply(configurationPlan: plan, for: analysis, scheme: "Demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("flow-review/config.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("flow-review/flows/new-flow.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("project.pbxproj").path))
    }
}
