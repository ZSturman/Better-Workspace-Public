import SwiftUI
import BetterWorkspaceCore

extension AppModel {
    func notionContent(for record: ProjectGraphRecord) async throws -> NotionPageContent? {
        guard let pageID = record.pageID else { return nil }
        let store = try ProjectGraphStore(database: database), key = "pageContent.\(pageID)"
        let cached = try store.read(key, as: NotionPageContent.self)
        if let cached, cached.editedAt == record.editedAt { return cached }
        guard let token = SecretStore.read(), !TestIsolation.isActive else { return cached }
        let fresh = try await NotionClient(token: token).pageContent(pageID: pageID, editedAt: record.editedAt)
        try store.write(key, fresh)
        return fresh
    }
}
struct ProjectNotionContentView: View {
    @Environment(AppModel.self) private var model
    let record: ProjectGraphRecord
    @State private var content: NotionPageContent?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let content, !content.blocks.isEmpty { ProjectNotionBlockReader(blocks: content.blocks, pageID: content.pageID) }
            if let error { Text("Notion content unavailable: " + error).font(.caption).foregroundStyle(.secondary) }
        }.task(id: record.editedAt) { @MainActor in
            if let pageID = record.pageID { content = try? ProjectGraphStore(database: model.database).read("pageContent.\(pageID)", as: NotionPageContent.self) }
            do { content = try await model.notionContent(for: record); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

/// Native reading hierarchy. Unsupported blocks remain in the cached snapshot.
private struct ProjectNotionBlockReader: View {
    let blocks: [ProjectJSON]
    let pageID: String
    var showControlLink = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in block(blocks[index], index: index) }
            if showControlLink, NotionPageContent.unsupportedBlockCount(blocks) > 0,
               let url = URL(string: "https://notion.so/" + pageID) {
                Link("Open Notion page for template buttons", destination: url).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func richText(_ parts: [ProjectJSON]) -> AttributedString {
        parts.reduce(into: AttributedString()) { result, part in
            var text = AttributedString(part.display)
            let annotation = part["annotations"]
            var intent: InlinePresentationIntent = []
            if annotation["bold"].bool { intent.insert(.stronglyEmphasized) }
            if annotation["italic"].bool { intent.insert(.emphasized) }
            if annotation["code"].bool { intent.insert(.code) }
            text.inlinePresentationIntent = intent
            if let address = part["text"]["link"]["url"].string ?? part["href"].string, let url = URL(string: address) { text.link = url }
            result += text
        }
    }
    private func block(_ block: ProjectJSON, index: Int) -> AnyView {
        let type = block["type"].string ?? "unsupported", value = block[block["type"].string ?? ""]
        let text = richText(value["rich_text"].array)
        let children = block["_children"].array
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            switch type {
            case "paragraph": Text(text).textSelection(.enabled)
            case "heading_1": Text(text).font(.title2.weight(.semibold)).padding(.top, 10)
            case "heading_2": Text(text).font(.title3.weight(.semibold)).padding(.top, 8)
            case "heading_3": Text(text).font(.headline).padding(.top, 5)
            case "bulleted_list_item", "numbered_list_item":
                HStack(alignment: .top, spacing: 8) {
                    Text(type == "bulleted_list_item" ? "•" : "\(blocks.prefix(index + 1).reversed().prefix { $0["type"].string == "numbered_list_item" }.count).")
                    Text(text).textSelection(.enabled)
                }
            case "to_do": HStack(alignment: .top) { Image(systemName: value["checked"].bool ? "checkmark.square" : "square").foregroundStyle(.secondary); Text(text).textSelection(.enabled) }
            case "quote", "callout": Text(text).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            case "code": Text(value["rich_text"].array.map(\.display).joined()).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            case "divider": Divider()
            case "toggle": DisclosureGroup { ProjectNotionBlockReader(blocks: children, pageID: pageID, showControlLink: false) } label: { Text(text) }
            case "synced_block", "column_list", "column", "unsupported": EmptyView()
            default:
                if !text.characters.isEmpty { Text(text).textSelection(.enabled) }
                if let url = URL(string: "https://notion.so/" + pageID) { Link("View \(type.replacingOccurrences(of: "_", with: " ")) in Notion", destination: url).font(.caption).foregroundStyle(.secondary) }
            }
            if !children.isEmpty && type != "toggle" {
                ProjectNotionBlockReader(blocks: children, pageID: pageID, showControlLink: false)
                    .padding(.leading, ["synced_block", "column_list", "column"].contains(type) ? 0 : 16)
            }
        })
    }
}
