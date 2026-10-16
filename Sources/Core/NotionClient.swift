import Foundation

/// Optional Notion transport shared by explicit imports, reviewed sync, and background detection.
public actor NotionClient {

    public enum Failure: LocalizedError {
        case noCredentials
        case http(Int, String)
        case transport(String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No Notion token is configured. Notion is optional — the rest of the app does not need one."
            case let .http(code, message):
                switch code {
                case 401: return "Notion rejected the token (401). Check the integration secret."
                case 404: return "Notion could not find that database (404). It may not be shared with the integration."
                case 429: return "Notion is rate limiting (429). Try the import again shortly."
                default: return "Notion answered \(code): \(message)"
                }
            case let .transport(message): return "Could not reach Notion: \(message)"
            case let .malformed(message): return "Notion sent something unexpected: \(message)"
            }
        }
    }

    /// The version this client is written against. Pinned, because Notion changes the
    /// shape of responses between versions and an import that silently reads a
    /// different shape is worse than one that fails.
    public static let apiVersion = "2026-03-11"

    private let token: String
    private let session: URLSession

    public init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    /// Every page in a database. Follows pagination to the end.
    ///
    /// - Parameter pageLimit: a stop so a runaway or enormous database cannot spin
    ///   forever. Hitting it is reported rather than silently truncating the import.
    public func allPages(inDatabase id: String, pageLimit: Int = 60) async throws -> (pages: [NotionPage], complete: Bool) {
        let source = try await graphSource(id)
        let result = try await graphPages(sourceID: source.id, pageLimit: pageLimit)
        return (result.pages.compactMap { NotionPage(json: $0.foundationObject) }, result.complete)
    }

    /// A database's own definition, used to confirm a token can see it before an
    /// import starts pulling thousands of rows.
    public func database(_ id: String) async throws -> NotionDatabase {
        let source = try await graphSource(id)
        return NotionDatabase(id: source.id, title: source.title, propertyNames: source.schema.object.keys.sorted(),
                              propertyTypes: source.schema.object.mapValues { $0["type"].string ?? "" })
    }

    /// Every database the integration has been shared with. Used to fill in the
    /// import's database ids by name, so nobody has to dig them out of page URLs.
    public func searchDatabases(pageLimit: Int = 10) async throws -> [NotionDatabase] {
        var out: [NotionDatabase] = []
        var cursor: String?
        var requests = 0
        repeat {
            var body: [String: Any] = ["page_size": 100,
                                       "filter": ["property": "object", "value": "data_source"]]
            if let cursor { body["start_cursor"] = cursor }
            let json = try await post("search", body: body)
            guard let results = json["results"] as? [[String: Any]] else {
                throw Failure.malformed("no results array from search")
            }
            out.append(contentsOf: results.compactMap(NotionDatabase.init(json:)))
            requests += 1
            cursor = (json["has_more"] as? Bool) == true ? json["next_cursor"] as? String : nil
        } while cursor != nil && requests < pageLimit
        return out
    }

    public func graphRequest(_ path: String, method: String = "GET", body: ProjectJSON? = nil) async throws -> ProjectJSON {
        ProjectJSON(try await send(request(path, method: method, body: body?.foundationObject)))
    }

    public func sendFileUpload(id: String, data: Data, filename: String, contentType: String) async throws -> ProjectJSON {
        let boundary = "bw-" + UUID().uuidString
        var request = request("file_uploads/\(id)/send", method: "POST", body: nil)
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let safeName = filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return ProjectJSON(try await send(request))
    }

    public func graphSource(_ id: String, kind: ProjectEntityKind? = nil) async throws -> ProjectGraphSource {
        let definition: ProjectJSON
        do { definition = try await graphRequest("data_sources/\(id)") }
        catch Failure.http(let code, _) where code == 404 || code == 400 {
            let database = try await graphRequest("databases/\(id)")
            guard let sourceID = database["data_sources"].array.first?["id"].string else { throw Failure.malformed("Database has no accessible data source") }
            definition = try await graphRequest("data_sources/\(sourceID)")
        }
        let title = definition["title"].display
        guard let sourceID = definition["id"].string else { throw Failure.malformed("Missing data source ID") }
        return ProjectGraphSource(id: sourceID, title: title, kind: kind ?? ProjectEntityKind.matching(title) ?? .projects, schema: definition["properties"])
    }

    public func graphPages(sourceID: String, since: Date? = nil, pageLimit: Int = 1000) async throws -> (pages: [ProjectJSON], complete: Bool) {
        var pages: [ProjectJSON] = [], cursor: String?, requests = 0, seen: Set<String> = []
        repeat {
            var body: [String: ProjectJSON] = ["page_size": .number(100)]
            if let cursor { body["start_cursor"] = .string(cursor) }
            if let since { body["filter"] = ProjectJSON(["timestamp": "last_edited_time", "last_edited_time": ["on_or_after": ISO8601DateFormatter().string(from: since)]]) }
            let result = try await graphRequest("data_sources/\(sourceID)/query", method: "POST", body: .object(body))
            guard case .array = result["results"] else { throw Failure.malformed("Missing results for \(sourceID)") }
            for page in result["results"].array { pages.append(try await completeProperties(page)) }
            requests += 1
            if result["has_more"].bool && result["next_cursor"].string == nil { throw Failure.malformed("Pagination reported more pages without a cursor") }
            cursor = result["has_more"].bool ? result["next_cursor"].string : nil
            if let cursor, !seen.insert(cursor).inserted { throw Failure.malformed("Page pagination repeated a cursor") }
        } while cursor != nil && requests < pageLimit
        return (pages, cursor == nil)
    }

    public func completeProperties(_ page: ProjectJSON) async throws -> ProjectJSON {
        var object = page.object, properties = page["properties"].object
        // Page responses cap references at 25. Only relations expose has_more;
        // mention/person arrays and dependent calculations need property reads too.
        let truncatedRelations = properties.values.contains { $0["type"].string == "relation" && $0["has_more"].bool }
        for (name, value) in properties {
            guard let type = value["type"].string else { continue }
            let cappedList = ["title", "rich_text", "people"].contains(type) && value[type].array.count >= 25
            let rollupNeedsRead = type == "rollup" && (truncatedRelations || value["rollup"]["type"].string == "incomplete" || value["rollup"]["array"].array.count >= 25)
            let formulaNeedsRead = type == "formula" && truncatedRelations
            guard value["has_more"].bool || cappedList || rollupNeedsRead || formulaNeedsRead else { continue }
            guard let pageID = page["id"].string, let propertyID = value["id"].string else {
                throw Failure.malformed("Incomplete property has no page or property ID")
            }
            let escaped = (propertyID.removingPercentEncoding ?? propertyID).addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? propertyID
            var items: [ProjectJSON] = [], cursor: String?, seen: Set<String> = [], rollup: ProjectJSON?
            var completed = value.object
            repeat {
                let escapedCursor = cursor?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#")))
                let suffix = escapedCursor.map { "?start_cursor=\($0)&page_size=100" } ?? "?page_size=100"
                let result = try await graphRequest("pages/\(pageID)/properties/\(escaped)" + suffix)
                if type == "formula" {
                    guard result["type"].string == "formula" else { throw Failure.malformed("Missing formula property result") }
                    completed["formula"] = result["formula"]
                    break
                }
                guard case .array = result["results"] else { throw Failure.malformed("Missing paginated property results") }
                if result["has_more"].bool && result["next_cursor"].string == nil { throw Failure.malformed("Property pagination has no cursor") }
                items.append(contentsOf: result["results"].array)
                if type == "rollup" { rollup = result["property_item"]["rollup"] }
                cursor = result["has_more"].bool ? result["next_cursor"].string : nil
                if let cursor, !seen.insert(cursor).inserted { throw Failure.malformed("Property pagination repeated a cursor") }
            } while cursor != nil
            if type == "rollup" {
                guard var final = rollup?.object, let resultType = final["type"]?.string, resultType != "incomplete" else {
                    throw Failure.malformed("Rollup calculation did not finish")
                }
                if resultType == "array" {
                    final["array"] = .array(items.map { item in
                        guard let itemType = item["type"].string else { return item }
                        return .object(["type": .string(itemType), itemType: item[itemType]])
                    })
                } else if resultType == "unsupported" {
                    // Preserve underlying values without inventing a computed result.
                    completed["property_items"] = .array(items)
                }
                completed["rollup"] = .object(final)
            } else if type != "formula" {
                completed[type] = .array(items.map { $0[type] })
            }
            if value.object["has_more"] != nil { completed["has_more"] = .bool(false) }
            properties[name] = .object(completed)
        }
        object["properties"] = .object(properties)
        return .object(object)
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> [String: Any] {
        try await send(request(path, method: "GET", body: nil))
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        try await send(request(path, method: "POST", body: body))
    }

    private func request(_ path: String, method: String, body: [String: Any]?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 40
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return request
    }

    /// How many times one request is tried before giving up.
    ///
    /// Notion rate-limits at around three requests a second and answers 429 with a
    /// `Retry-After`. An import reads five databases and paginates each of them, so being
    /// rate-limited partway through is ordinary rather than exceptional — and failing the
    /// whole import for it throws away several thousand rows of work that were already
    /// fetched. Bounded, because a database that answers 429 forever is a real problem
    /// someone should be told about rather than waited out.
    public static let maxAttempts = 4

    /// How long to wait before trying the same request again, or nil when trying again
    /// is pointless. A rate limit and a server error are worth waiting out; a 401 or a
    /// 404 will be exactly the same in ten seconds.
    static func retryDelay(forStatus code: Int, retryAfter: Double?,
                           attempt: Int, maxAttempts: Int = maxAttempts) -> Duration? {
        guard attempt < maxAttempts else { return nil }
        guard code == 429 || (500..<600).contains(code) else { return nil }
        // Honor Retry-After; cancellation can interrupt a long server-requested wait.
        let seconds = retryAfter ?? pow(2, Double(attempt))
        return .seconds(max(seconds, 0.5))
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        // An isolated UI-test launch never reaches a real workspace, whatever token its
        // keychain holds. Unit tests pass their own session and are not isolated launches.
        if TestIsolation.isActive && session === URLSession.shared && TestIsolation.launchArgument("bwAllowNotionNetwork") == nil {
            throw Failure.transport("Isolated test runs never contact Notion.")
        }
        var attempt = 1
        while true {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw Failure.transport(error.localizedDescription)
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            if (200..<300).contains(code) {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Failure.malformed("response was not a JSON object")
                }
                return json
            }
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let retryableWrite = code == 429 || code == 529
            guard (request.httpMethod != "POST" || request.url?.path.hasSuffix("query") == true || request.url?.path.hasSuffix("search") == true || retryableWrite),
                  let delay = Self.retryDelay(forStatus: code, retryAfter: retryAfter, attempt: attempt) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                throw Failure.http(code, message ?? "")
            }
            try await Task.sleep(for: delay)
            attempt += 1
        }
    }
}

public struct NotionDatabase: Sendable {
    public let id: String
    public let title: String
    public let propertyNames: [String]
    /// Present for schema audit and selective import mapping.  The page reader still
    /// treats unknown value envelopes as unsupported rather than guessing.
    public let propertyTypes: [String: String]

    public init(id: String, title: String, propertyNames: [String] = [], propertyTypes: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.propertyNames = propertyNames
        self.propertyTypes = propertyTypes
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        let titleParts = (json["title"] as? [[String: Any]]) ?? []
        title = titleParts.compactMap { $0["plain_text"] as? String }.joined()
        let properties = (json["properties"] as? [String: Any]) ?? [:]
        propertyNames = properties.keys.sorted()
        propertyTypes = properties.compactMapValues { ($0 as? [String: Any])?["type"] as? String }
    }
}

/// One row, with its properties flattened into values this app can actually use.
///
/// Notion wraps every value in a type envelope. Flattening once here means the mapping
/// code reads like the data rather than like the API.
public struct NotionPage: Sendable {
    public let id: String
    public let url: URL?
    public let createdTime: Date?
    public let lastEditedTime: Date?
    public let properties: [String: NotionValue]

    public func text(_ name: String) -> String? {
        guard case let .text(value)? = properties[name], value.isEmpty == false else { return nil }
        return value
    }

    public func choice(_ name: String) -> String? {
        guard case let .choice(value)? = properties[name] else { return nil }
        return value
    }

    public func choices(_ name: String) -> [String] {
        guard case let .choices(values)? = properties[name] else { return [] }
        return values
    }

    public func number(_ name: String) -> Double? {
        guard case let .number(value)? = properties[name] else { return nil }
        return value
    }

    public func flag(_ name: String) -> Bool {
        guard case let .flag(value)? = properties[name] else { return false }
        return value
    }

    public func date(_ name: String) -> String? {
        guard case let .date(value)? = properties[name] else { return nil }
        return value
    }

    public func relations(_ name: String) -> [String] {
        guard case let .relations(values)? = properties[name] else { return [] }
        return values
    }

    /// The row's title, whatever the title property happens to be called.
    public var title: String? {
        for (_, value) in properties {
            if case let .title(text) = value, text.isEmpty == false { return text }
        }
        return nil
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        url = (json["url"] as? String).flatMap(URL.init(string:))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func parse(_ key: String) -> Date? {
            guard let raw = json[key] as? String else { return nil }
            return formatter.date(from: raw) ?? plain.date(from: raw)
        }
        createdTime = parse("created_time")
        lastEditedTime = parse("last_edited_time")
        properties = ((json["properties"] as? [String: Any]) ?? [:])
            .compactMapValues { NotionValue(json: $0) }
    }

    /// For tests and previews, without going near the network.
    public init(id: String, url: URL? = nil, createdTime: Date? = nil,
                lastEditedTime: Date? = nil, properties: [String: NotionValue]) {
        self.id = id
        self.url = url
        self.createdTime = createdTime
        self.lastEditedTime = lastEditedTime
        self.properties = properties
    }
}

/// A Notion property value, reduced to the handful of shapes that matter here.
///
/// Formulas and rollups arrive as whatever they computed and are treated as read-only
/// text. Reviewed graph writes use the lossless schema-aware ProjectJSON model and
/// never send computed properties.
public enum NotionValue: Sendable, Hashable {
    case title(String)
    case text(String)
    case choice(String)
    case choices([String])
    case number(Double)
    case flag(Bool)
    case date(String)
    case relations([String])

    init?(json: Any) {
        guard let property = json as? [String: Any], let type = property["type"] as? String else { return nil }
        switch type {
        case "title":
            self = .title(Self.plain(property["title"]))
        case "rich_text":
            self = .text(Self.plain(property["rich_text"]))
        case "select":
            guard let name = (property["select"] as? [String: Any])?["name"] as? String else { return nil }
            self = .choice(name)
        case "status":
            guard let name = (property["status"] as? [String: Any])?["name"] as? String else { return nil }
            self = .choice(name)
        case "multi_select":
            let names = ((property["multi_select"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            self = .choices(names)
        case "number":
            guard let value = property["number"] as? Double else { return nil }
            self = .number(value)
        case "checkbox":
            self = .flag((property["checkbox"] as? Bool) ?? false)
        case "date":
            guard let start = (property["date"] as? [String: Any])?["start"] as? String else { return nil }
            self = .date(start)
        case "url":
            guard let value = property["url"] as? String, value.isEmpty == false else { return nil }
            self = .text(value)
        case "relation":
            let ids = ((property["relation"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            self = .relations(ids)
        case "formula":
            guard let formula = property["formula"] as? [String: Any] else { return nil }
            if let value = formula["string"] as? String { self = .text(value) }
            else if let value = formula["number"] as? Double { self = .number(value) }
            else if let value = formula["boolean"] as? Bool { self = .flag(value) }
            else { return nil }
        default:
            return nil
        }
    }

    private static func plain(_ parts: Any?) -> String {
        ((parts as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }
}
