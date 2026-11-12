import Foundation

public struct ProjectLink: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var url: String
    public init(id: UUID = UUID(), label: String = "", url: String = "") {
        self.id = id; self.label = label; self.url = url
    }
    public var destination: URL? {
        guard let value = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""), value.host?.isEmpty == false else { return nil }
        return value
    }
}

/// Presentation and validation over the existing private project fields.
public enum ProjectProperties {
    public static func types(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: ",").reduce(into: []) { result, part in
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !result.contains(where: { TagMatching.equivalent($0, value) }) { result.append(value) }
        }
    }
    public static func validate(_ details: ProjectPortfolioDetails) throws {
        let links = (details.customLinks ?? []) + [details.githubURL, details.websiteURL].compactMap { $0 }.map { ProjectLink(label: "Link", url: $0) }
        guard links.count <= 32, Set((details.customLinks ?? []).map(\.id)).count == (details.customLinks ?? []).count,
              links.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.utf8.count <= 200 && $0.url.utf8.count <= 2048 && $0.destination != nil }) else {
            throw MobilePlanningFiles.Error.invalid("Give each link a name and a complete http:// or https:// address (up to 32 links).")
        }
    }
    public static func validateChanges(_ details: ProjectPortfolioDetails, from original: ProjectPortfolioDetails) throws {
        var changed = ProjectPortfolioDetails()
        if details.githubURL != original.githubURL { changed.githubURL = details.githubURL }
        if details.websiteURL != original.websiteURL { changed.websiteURL = details.websiteURL }
        if details.customLinks != original.customLinks { changed.customLinks = details.customLinks }
        try validate(changed)
    }
    /// Sparse, stale-checked edits leave unrelated references and sync metadata alone.
    public static func merging(_ desired: ProjectPortfolioDetails, original: ProjectPortfolioDetails, current: ProjectPortfolioDetails) throws -> ProjectPortfolioDetails {
        var result = current
        func apply<T: Equatable>(_ path: WritableKeyPath<ProjectPortfolioDetails, T>) throws {
            guard desired[keyPath: path] != original[keyPath: path] else { return }
            guard current[keyPath: path] == original[keyPath: path] || current[keyPath: path] == desired[keyPath: path] else { throw MobilePlanningFiles.Error.conflict }
            result[keyPath: path] = desired[keyPath: path]
        }
        try apply(\.featured); try apply(\.inShowcase); try apply(\.isPublic)
        try apply(\.githubURL); try apply(\.websiteURL); try apply(\.customLinks)
        return result
    }
    public static func queryRecord(id: String, name: String, metadata: ProjectMetadata, portfolio: ProjectPortfolioDetails) -> ProjectQueryRecord {
        .init(id: id, name: name, values: ["domain": metadata.domain ?? "", "status": metadata.status ?? "", "type": metadata.projectType ?? "", "featured": portfolio.featured == true ? "Yes" : "No"], selections: ["type": types(metadata.projectType)])
    }
}

extension MobileProjectDetails {
    public var editablePortfolio: ProjectPortfolioDetails { portfolio ?? .init(githubURL: githubURL, websiteURL: websiteURL) }
}
