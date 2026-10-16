import Foundation

/// Native project-tooling capability.  It is intentionally derived from a small,
/// shallow scan: selecting a project must not start a recursive repository walk.
public struct ProjectToolCapability: Sendable, Hashable {
    public let canExplain: Bool
    public let canFlowReview: Bool
    public let reason: String?

    public init(canExplain: Bool, canFlowReview: Bool, reason: String? = nil) {
        self.canExplain = canExplain
        self.canFlowReview = canFlowReview
        self.reason = reason
    }
}

public actor ProjectToolCapabilityService {
    public static let shared = ProjectToolCapabilityService()
    private var cache: [String: ProjectToolCapability] = [:]

    public func capability(for url: URL) -> ProjectToolCapability {
        let key = url.canonicalPath
        if let cached = cache[key] { return cached }
        let result = Self.scan(url)
        cache[key] = result
        return result
    }

    public func invalidate(path: String? = nil) {
        guard let path else { cache.removeAll(); return }
        cache.removeValue(forKey: URL(fileURLWithPath: path).canonicalPath)
    }

    private nonisolated static func scan(_ url: URL) -> ProjectToolCapability {
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            return .init(canExplain: false, canFlowReview: false, reason: "Select a folder")
        }
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
        let manifests: Set<String> = ["Package.swift", "package.json", "pyproject.toml", "requirements.txt", "setup.py", "Cargo.toml", "go.mod", "Gemfile"]
        let docs = names.contains { $0.lowercased().hasPrefix("readme") || $0.lowercased().hasPrefix("design") }
        let hasSources = names.contains { name in
            ["swift", "m", "mm", "h", "py", "js", "ts", "tsx", "jsx", "rb", "rs", "go", "java", "kt", "c", "cc", "cpp"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
        }
        let xcode = names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        return .init(canExplain: names.contains(".git") || docs || hasSources || names.isDisjoint(with: manifests) == false,
                     canFlowReview: xcode,
                     reason: xcode ? nil : "No supported Xcode project found")
    }
}

public struct ProjectToolEvidence: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: String
    public let detail: String
    public let path: String?
    public let line: Int?

    public init(kind: String, detail: String, path: String? = nil, line: Int? = nil) {
        self.id = UUID(); self.kind = kind; self.detail = detail; self.path = path; self.line = line
    }
}

public struct ProjectToolFinding: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let statement: String
    public let confidence: String
    public let evidence: [ProjectToolEvidence]

    public init(title: String, statement: String, confidence: String, evidence: [ProjectToolEvidence]) {
        self.id = UUID(); self.title = title; self.statement = statement; self.confidence = confidence; self.evidence = evidence
    }
}

public struct ProjectToolAction: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
}

public struct ProjectExplanationReport: Codable, Sendable {
    public let projectPath: String
    public let projectName: String
    public let fileSignature: String
    public let sourceFileCount: Int
    public let languages: [String]
    public let manifests: [String]
    public let findings: [ProjectToolFinding]
    public let actions: [ProjectToolAction]
    public let createdAt: Date
}

public struct ProjectInvestigation: Codable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let question: String
    public let findings: [ProjectToolFinding]
    public let filesExamined: [String]

    public init(title: String, question: String, findings: [ProjectToolFinding], filesExamined: [String]) {
        self.id = UUID(); self.title = title; self.question = question; self.findings = findings; self.filesExamined = filesExamined
    }
}

public struct VerificationCommand: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let command: [String]
    public let available: Bool
    public let reason: String
}

public struct VerificationPlan: Codable, Sendable, Identifiable {
    public let projectPath: String
    public let commands: [VerificationCommand]
    public let safetyNote: String
    public var id: String { projectPath }
}

/// Read-only project forensics.  The implementation deliberately reads bounded text
/// samples and metadata only; it never invokes an inspected repository during normal
/// analysis or investigation.
public actor ProjectExplanationService {
    public static let shared = ProjectExplanationService()
    private let fm = FileManager.default

    public func analyze(at root: URL) -> ProjectExplanationReport {
        let root = root.canonical
        var sources = 0, todos = 0
        var languages = Set<String>(), manifests = [String](), important = [String]()
        var newest: Date?
        let manifestNames: Set<String> = ["Package.swift", "package.json", "pyproject.toml", "requirements.txt", "setup.py", "Cargo.toml", "go.mod", "Gemfile"]
        let ignored: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods", "vendor", ".flow-review"]
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            var examined = 0
            for case let url as URL in walker where examined < 12_000 {
                let name = url.lastPathComponent
                if ignored.contains(name) { walker.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                if values?.isDirectory == true { continue }
                examined += 1
                if manifestNames.contains(name) { manifests.append(root.relativePath(to: url)) }
                if let language = Self.language(for: url) { sources += 1; languages.insert(language) }
                if let date = values?.contentModificationDate, newest == nil || date > newest! { newest = date }
                if important.count < 12, Self.language(for: url) != nil { important.append(root.relativePath(to: url)) }
                if todos < 100, let text = Self.readPrefix(url, bytes: 48 * 1024) {
                    todos += text.components(separatedBy: .newlines).filter { $0.localizedCaseInsensitiveContains("TODO") || $0.localizedCaseInsensitiveContains("FIXME") }.count
                }
            }
        }
        let isGit = fm.fileExists(atPath: root.appendingPathComponent(".git").path)
        var findings: [ProjectToolFinding] = [
            .init(title: "Project shape", statement: "Found \(sources) source file\(sources == 1 ? "" : "s") in \(languages.sorted().joined(separator: ", ").nonEmpty ?? "an unrecognised language").", confidence: "confirmed", evidence: [.init(kind: "filesystem", detail: "Bounded static scan; manifests: \(manifests.isEmpty ? "none" : manifests.joined(separator: ", "))")])
        ]
        if isGit { findings.append(.init(title: "Git metadata", statement: "A local Git repository is present. Normal Explain analysis reads metadata and never changes Git state.", confidence: "confirmed", evidence: [.init(kind: "git", detail: "Found .git directory")])) }
        if todos > 0 { findings.append(.init(title: "Unfinished-work signals", statement: "Found \(todos) TODO/FIXME marker\(todos == 1 ? "" : "s") in bounded source samples.", confidence: "likely", evidence: [.init(kind: "source", detail: "Markers are static signals, not proof of unfinished behaviour")])) }
        if let newest { findings.append(.init(title: "Recent sampled activity", statement: "The newest file sampled was modified \(newest.formatted(date: .abbreviated, time: .shortened)).", confidence: "confirmed", evidence: [.init(kind: "filesystem", detail: "Modification date from file metadata")])) }
        let actions = [
            ProjectToolAction(id: "inspect-sources", title: "Inspect source layout", description: "Review the most representative source files."),
            ProjectToolAction(id: "inspect-unfinished", title: "Investigate unfinished work", description: "Trace TODO/FIXME markers and surrounding files."),
            ProjectToolAction(id: "verification", title: "Prepare verification", description: "Preview safe allowlisted checks before anything executes.")
        ]
        let signature = "\(sources)|\(todos)|\(newest?.timeIntervalSince1970 ?? 0)|\(manifests.sorted().joined(separator: ","))"
        return .init(projectPath: root.path, projectName: root.lastPathComponent, fileSignature: signature, sourceFileCount: sources, languages: languages.sorted(), manifests: manifests.sorted(), findings: findings, actions: actions, createdAt: .now)
    }

    public func investigate(_ action: ProjectToolAction, report: ProjectExplanationReport) -> ProjectInvestigation {
        let root = URL(fileURLWithPath: report.projectPath)
        let files = Self.representativeFiles(in: root, limit: 14)
        let message: String
        switch action.id {
        case "inspect-unfinished": message = "Review the static TODO/FIXME markers in the selected source sample before deciding whether the work is still relevant."
        default: message = "These files are representative of the project layout discovered by Explain."
        }
        return .init(title: action.title, question: action.description,
                     findings: [.init(title: action.title, statement: message, confidence: "unexplored", evidence: files.prefix(6).map { .init(kind: "file", detail: "Selected for bounded inspection", path: $0) })], filesExamined: files)
    }

    public func answer(_ question: String, in report: ProjectExplanationReport) -> ProjectInvestigation {
        let tokens = question.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init).filter { $0.count >= 3 }
        let files = Self.representativeFiles(in: URL(fileURLWithPath: report.projectPath), limit: 80)
        let matches = files.filter { file in tokens.contains { file.localizedCaseInsensitiveContains($0) } }
        let statement = matches.isEmpty ? "No filename in the bounded project sample directly matched this question. Use a follow-up investigation or local AI for interpretation." : "Matched \(matches.count) file name\(matches.count == 1 ? "" : "s") against terms in your question."
        return .init(title: "Question", question: question, findings: [.init(title: "Evidence-backed answer", statement: statement, confidence: matches.isEmpty ? "unexplored" : "likely", evidence: matches.prefix(8).map { .init(kind: "filename", detail: "Matches a question term", path: $0) })], filesExamined: matches)
    }

    public func verificationPlan(for report: ProjectExplanationReport) -> VerificationPlan {
        let root = URL(fileURLWithPath: report.projectPath)
        var commands: [VerificationCommand] = []
        if fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) { commands.append(.init(id: "swift-test", name: "Swift tests", command: ["swift", "test"], available: true, reason: "Swift Package manifest found")) }
        if fm.fileExists(atPath: root.appendingPathComponent("pyproject.toml").path) || fm.fileExists(atPath: root.appendingPathComponent("pytest.ini").path) { commands.append(.init(id: "pytest", name: "Python tests", command: ["python3", "-m", "pytest"], available: true, reason: "Python test configuration found")) }
        if (try? fm.contentsOfDirectory(atPath: root.path))?.contains(where: { $0.hasSuffix(".xcodeproj") }) == true { commands.append(.init(id: "xcodebuild-test", name: "Xcode tests", command: ["xcodebuild", "test"], available: true, reason: "Xcode project found; select a scheme before execution")) }
        return .init(projectPath: root.path, commands: commands, safetyNote: "Nothing has run. Execution is explicit, limits each direct allowlisted command to 90 seconds, and never runs repository-defined npm scripts.")
    }

    private nonisolated static func language(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "swift": return "Swift"; case "py": return "Python"; case "js", "jsx": return "JavaScript"; case "ts", "tsx": return "TypeScript"; case "rb": return "Ruby"; case "rs": return "Rust"; case "go": return "Go"; case "c", "h", "m", "mm", "cc", "cpp": return "C-family"; case "java", "kt": return "JVM"; default: return nil
        }
    }
    private nonisolated static func readPrefix(_ url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }; defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }; return String(data: data, encoding: .utf8)
    }
    private nonisolated static func representativeFiles(in root: URL, limit: Int) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }.prefix(limit).map { root.relativePath(to: $0) }
    }
}

public struct FlowReviewAnalysis: Sendable, Codable {
    public let projectPath: String
    public let xcodeProjectPath: String?
    public let schemes: [String]
    public let flowFiles: [String]
    public let configured: Bool
    public let blockingReason: String?
    public var readyToRun: Bool { configured && flowFiles.isEmpty == false && xcodeProjectPath != nil }
}

public struct FlowReviewChange: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let path: String
    public let summary: String
}

/// Native Flow Review planning.  Configuration changes are deliberately isolated to
/// the selected project and require the caller to present this plan before applying it.
public actor FlowReviewService {
    public static let shared = FlowReviewService()
    private let fm = FileManager.default

    public func analyze(at root: URL) -> FlowReviewAnalysis {
        let root = root.canonical
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let xcode = entries.first(where: { $0.pathExtension == "xcodeproj" })
        let config = root.appendingPathComponent("flow-review/config.yaml")
        let flows = ((try? fm.contentsOfDirectory(at: root.appendingPathComponent("flow-review/flows"), includingPropertiesForKeys: nil)) ?? [])
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }.map { root.relativePath(to: $0) }.sorted()
        let schemes = xcode.map { Self.sharedSchemes(in: $0) } ?? []
        let reason = xcode == nil ? "No .xcodeproj was found in this folder." : nil
        return .init(projectPath: root.path, xcodeProjectPath: xcode?.path, schemes: schemes, flowFiles: flows, configured: fm.fileExists(atPath: config.path), blockingReason: reason)
    }

    public func configurationPlan(for analysis: FlowReviewAnalysis, scheme: String?) -> [FlowReviewChange] {
        var changes: [FlowReviewChange] = []
        if !analysis.configured { changes.append(.init(id: "config", path: "flow-review/config.yaml", summary: "Create Flow Review configuration")) }
        if analysis.flowFiles.isEmpty { changes.append(.init(id: "starter-flow", path: "flow-review/flows/new-flow.yaml", summary: "Create an editable starter flow")) }
        changes.append(.init(id: "generated", path: ".flow-review/generated", summary: "Generate disposable test resources for \(scheme ?? analysis.schemes.first ?? "the selected scheme")"))
        return changes
    }

    public func apply(configurationPlan changes: [FlowReviewChange], for analysis: FlowReviewAnalysis, scheme: String?) throws {
        let root = URL(fileURLWithPath: analysis.projectPath)
        for change in changes {
            let destination = root.appendingPathComponent(change.path)
            switch change.id {
            case "config":
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let xcodeName = analysis.xcodeProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                let text = "# Created by Better Workspace after explicit confirmation\nxcode:\n  project: \(xcodeName)\n  scheme: \(scheme ?? analysis.schemes.first ?? "")\nrun:\n  review_delay_ms: 700\n"
                try text.write(to: destination, atomically: false, encoding: .utf8)
            case "starter-flow":
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "id: new-flow\nname: New Flow\ntags: []\nsteps:\n  - launch\n  - checkpoint:\n      name: initial\n".write(to: destination, atomically: false, encoding: .utf8)
            case "generated":
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            default: break
            }
        }
    }

    private nonisolated static func sharedSchemes(in project: URL) -> [String] {
        let schemeDir = project.appendingPathComponent("xcshareddata/xcschemes")
        return ((try? FileManager.default.contentsOfDirectory(at: schemeDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "xcscheme" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
}

private extension URL {
    func relativePath(to child: URL) -> String {
        let prefix = canonicalPath.hasSuffix("/") ? canonicalPath : canonicalPath + "/"
        let path = child.canonicalPath
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : child.lastPathComponent
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
