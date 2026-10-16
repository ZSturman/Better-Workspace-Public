import SwiftUI
import BetterWorkspaceCore

/// One shared local provider for optional project metadata suggestions.
/// Retains the earlier setting keys so configured installations keep their connection.
enum LMStudioConnection {
    static let client: LMStudioClient = {
        guard TestIsolation.isActive else { return LMStudioClient() }
        // UI fixtures must never send project data to the person's running model.
        return LMStudioClient { request, limit in
            guard let sandbox = TestIsolation.sandbox,
                  let path = TestIsolation.launchArgument("bwLMStudioFixture"),
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().canonicalPath.hasPrefix(sandbox.resolvingSymlinksInPath().canonicalPath + "/") else {
                throw LMStudioError.invalidResponse("isolated tests require a sandbox response fixture")
            }
            try Task.checkCancellation()
            let data: Data
            if request.url?.lastPathComponent == "models" { data = Data(#"{"models":[{"key":"fixture-model","type":"llm"}]}"#.utf8) }
            else {
                if let milliseconds = TestIsolation.launchArgument("bwLMStudioFixtureDelayMS").flatMap(Int.init) {
                    try await Task.sleep(for: .milliseconds(max(0, min(milliseconds, 10_000))))
                }
                let url = URL(fileURLWithPath: path)
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= limit else { throw LMStudioError.tooLarge }
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }()
}

struct ProjectZenAISettings: View {
    var body: some View {
        Section {
            LMStudioConnectionFields()
        } header: {
            Text("LM Studio")
        } footer: {
            Text("Optional. Suggests project details from a model running on this Mac; nothing is saved until you apply it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LMStudioConnectionFields: View {
    @AppStorage("projectZenAIEndpoint", store: TestIsolation.defaults) private var endpoint = LMStudioPreset.endpoint
    @AppStorage("projectZenAIModel", store: TestIsolation.defaults) private var model = ""
    @AppStorage("projectLMStudioSchema", store: TestIsolation.defaults) private var schema = true
    @State private var models: [String] = []
    @State private var problem: String?
    @State private var discovering = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Local endpoint", text: $endpoint, prompt: Text("http://127.0.0.1:1234/v1")).accessibilityIdentifier("lmStudio.endpoint")
            HStack {
                if models.isEmpty { Text(discovering ? "Finding available chat models…" : "No available chat model verified").foregroundStyle(.secondary) }
                else {
                    Picker("Model", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }.accessibilityIdentifier("lmStudio.model")
                }
                Button(discovering ? "Discovering…" : "Refresh models") { discover() }
                    .disabled(discovering).accessibilityIdentifier("lmStudio.discover")
            }
            .help("The saved model is used when available; otherwise the tested Qwen preset, then the first available chat model. Embedding models are excluded, and nothing is downloaded.")
            Toggle("Request JSON schema (if supported by this model)", isOn: $schema)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }.task { discover() }
            .onChange(of: endpoint) { _, _ in models = []; task?.cancel(); discover() }
            .onDisappear { task?.cancel() }
    }
    private func discover() {
        task?.cancel(); discovering = true; problem = nil
        let approvedEndpoint = endpoint
        task = Task { @MainActor in
            defer { discovering = false }
            do {
                let available = try await LMStudioConnection.client.models(endpoint: approvedEndpoint)
                try Task.checkCancellation()
                guard endpoint == approvedEndpoint else { return }
                models = available
                model = LMStudioPreset.choose(saved: model, available: available) ?? ""
                if available.isEmpty { problem = "No chat models are available. Add a model in LM Studio, then refresh." }
            } catch is CancellationError {} catch { models = []; model = ""; problem = error.localizedDescription }
        }
    }
}
