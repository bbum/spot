import Foundation

// MARK: - JSON-RPC Types

struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: RequestID?
    let method: String
    let params: JSONValue?

    enum RequestID: Codable, Sendable {
        case string(String)
        case int(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int.self) {
                self = .int(intVal)
            } else if let strVal = try? container.decode(String.self) {
                self = .string(strVal)
            } else {
                throw DecodingError.typeMismatch(RequestID.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string or int"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let s): try container.encode(s)
            case .int(let i): try container.encode(i)
            }
        }
    }
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: JSONRPCRequest.RequestID?
    let result: JSONValue?
    let error: JSONRPCError?

    init(id: JSONRPCRequest.RequestID?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: JSONRPCRequest.RequestID?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: JSONValue?

    static func parseError(_ msg: String) -> JSONRPCError {
        JSONRPCError(code: -32700, message: msg, data: nil)
    }

    static func invalidRequest(_ msg: String) -> JSONRPCError {
        JSONRPCError(code: -32600, message: msg, data: nil)
    }

    static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)", data: nil)
    }

    static func invalidParams(_ msg: String) -> JSONRPCError {
        JSONRPCError(code: -32602, message: msg, data: nil)
    }

    static func internalError(_ msg: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: msg, data: nil)
    }
}

// MARK: - JSON Value (dynamic)

enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unknown JSON type"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let obj) = self {
            return obj[key]
        }
        return nil
    }
}

// MARK: - MCP Server

final class MCPServer {
    private let executor = SpotlightQueryExecutor()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let isoFormatter = ISO8601DateFormatter()

    init() {
        encoder.outputFormatting = [] // Compact
        encoder.dateEncodingStrategy = .iso8601
    }

    func run() async {
        while let line = readLine() {
            guard !line.isEmpty else { continue }

            do {
                let request = try decoder.decode(JSONRPCRequest.self, from: Data(line.utf8))
                let response = await handleRequest(request)
                sendResponse(response)
            } catch {
                let errorResponse = JSONRPCResponse(id: nil, error: .parseError(error.localizedDescription))
                sendResponse(errorResponse)
            }
        }
    }

    private func sendResponse(_ response: JSONRPCResponse) {
        do {
            let data = try encoder.encode(response)
            if let json = String(data: data, encoding: .utf8) {
                print(json)
                fflush(stdout)
            }
        } catch {
            // Last resort error
            print("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Encoding error\"}}")
            fflush(stdout)
        }
    }

    private func handleRequest(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "initialized":
            return JSONRPCResponse(id: request.id, result: .object([:]))
        case "tools/list":
            return handleToolsList(request)
        case "tools/call":
            return await handleToolsCall(request)
        case "notifications/initialized":
            // Notification, no response needed but we'll send empty
            return JSONRPCResponse(id: request.id, result: .object([:]))
        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }

    // MARK: - Initialize

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let result: JSONValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "serverInfo": .object([
                "name": .string("mdagent"),
                "version": .string("1.0.0")
            ]),
            "capabilities": .object([
                "tools": .object([:])
            ])
        ])
        return JSONRPCResponse(id: request.id, result: result)
    }

    // MARK: - Tools List

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        // Compact tool description - all docs in description field to minimize tokens
        let searchDesc = """
Spotlight search. Query: @name:*.swift @content:TODO @kind:folder @type:public.swift-source @mod:7 @size:>1M (or raw MDQuery). Returns path|size|date.
"""
        let tools: JSONValue = .object([
            "tools": .array([
                .object([
                    "name": .string("search"),
                    "description": .string(searchDesc),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "q": .object(["type": .string("string")]),
                            "in": .object(["type": .string("string")]),
                            "n": .object(["type": .string("integer")]),
                            "sort": .object(["type": .string("string")]),
                            "fmt": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("q")])
                    ])
                ]),
                .object([
                    "name": .string("count"),
                    "description": .string("Count matching files. Same query syntax as search."),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "q": .object(["type": .string("string")]),
                            "in": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("q")])
                    ])
                ]),
                .object([
                    "name": .string("meta"),
                    "description": .string("Get file metadata via Spotlight."),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("path")])
                    ])
                ])
            ])
        ])
        return JSONRPCResponse(id: request.id, result: tools)
    }

    // MARK: - Tools Call

    private func handleToolsCall(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let params = request.params?.objectValue,
              let name = params["name"]?.stringValue else {
            return JSONRPCResponse(id: request.id, error: .invalidParams("Missing tool name"))
        }

        let args = params["arguments"]?.objectValue ?? [:]

        do {
            let result: String
            switch name {
            case "search":
                result = try await executeSearch(args)
            case "count":
                result = try await executeCount(args)
            case "meta":
                result = try await executeMetadata(args)
            default:
                return JSONRPCResponse(id: request.id, error: .methodNotFound("Unknown tool: \(name)"))
            }

            let response: JSONValue = .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(result)
                    ])
                ])
            ])
            return JSONRPCResponse(id: request.id, result: response)
        } catch {
            return JSONRPCResponse(id: request.id, error: .internalError(error.localizedDescription))
        }
    }

    // MARK: - Tool Implementations

    private func executeSearch(_ args: [String: JSONValue]) async throws -> String {
        guard let queryInput = args["q"]?.stringValue else {
            throw NSError(domain: "mdagent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing query parameter 'q'"])
        }

        let query = parseQueryShorthand(queryInput)
        let scopes = args["in"]?.stringValue?.split(separator: ",").map(String.init)
        let limit = args["n"]?.intValue ?? 100
        let sortSpec = args["sort"]?.stringValue
        let format = args["fmt"]?.stringValue ?? "compact"

        var sortBy: String? = nil
        var descending = true

        if let sort = sortSpec {
            let cleanSort: String
            if sort.hasPrefix("-") {
                descending = true
                cleanSort = String(sort.dropFirst())
            } else {
                descending = false
                cleanSort = sort
            }

            switch cleanSort {
            case "name": sortBy = kMDItemFSName as String
            case "date": sortBy = kMDItemContentModificationDate as String
            case "size": sortBy = kMDItemFSSize as String
            case "created": sortBy = kMDItemFSCreationDate as String
            default: sortBy = cleanSort // Allow raw attribute names
            }
        }

        let results = try await executor.execute(
            query: query,
            scopes: scopes,
            limit: limit,
            sortBy: sortBy,
            descending: descending
        )

        switch format {
        case "paths":
            return results.map(\.path).joined(separator: "\n")
        case "full":
            return formatFullResults(results)
        default: // compact
            return results.map(\.compact).joined(separator: "\n")
        }
    }

    private func executeCount(_ args: [String: JSONValue]) async throws -> String {
        guard let queryInput = args["q"]?.stringValue else {
            throw NSError(domain: "mdagent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing query parameter 'q'"])
        }

        let query = parseQueryShorthand(queryInput)
        let scopes = args["in"]?.stringValue?.split(separator: ",").map(String.init)

        let count = try await executor.count(query: query, scopes: scopes)
        return "\(count)"
    }

    private func executeMetadata(_ args: [String: JSONValue]) async throws -> String {
        guard let path = args["path"]?.stringValue else {
            throw NSError(domain: "mdagent", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing path parameter"])
        }

        return try await executor.metadata(path: path)
    }

    // MARK: - Helpers

    private func parseQueryShorthand(_ input: String) -> String {
        // If it starts with kMD, assume raw query
        if input.hasPrefix("kMD") {
            return input
        }

        var components: [String] = []

        // Parse shorthand patterns
        let patterns: [(String, (String) -> String)] = [
            ("@name:", { QueryBuilder.filename($0) }),
            ("@content:", { QueryBuilder.content($0) }),
            ("@kind:", { QueryBuilder.kind($0) }),
            ("@type:", { QueryBuilder.contentType($0) }),
            ("@tree:", { QueryBuilder.contentTypeTree($0) }),
            ("@mod:", { self.parseDateOrSize($0, isDate: true, isModified: true) }),
            ("@created:", { self.parseDateOrSize($0, isDate: true, isModified: false) }),
            ("@size:", { self.parseSizeQuery($0) })
        ]

        var remaining = input

        for (prefix, builder) in patterns {
            while let range = remaining.range(of: prefix) {
                // Find the value after the prefix
                let afterPrefix = remaining[range.upperBound...]
                let endIndex = afterPrefix.firstIndex(where: { $0 == " " }) ?? afterPrefix.endIndex
                let value = String(afterPrefix[..<endIndex])

                if !value.isEmpty {
                    components.append(builder(value))
                }

                // Remove this pattern from remaining
                let fullRange = range.lowerBound..<(endIndex == afterPrefix.endIndex ? remaining.endIndex : remaining.index(after: endIndex))
                remaining.removeSubrange(fullRange)
            }
        }

        // If nothing matched, treat as filename glob
        remaining = remaining.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty && components.isEmpty {
            components.append(QueryBuilder.filename(remaining))
        } else if !remaining.isEmpty {
            // Leftover treated as filename pattern
            components.append(QueryBuilder.filename(remaining))
        }

        return components.isEmpty ? "kMDItemFSName == \"*\"" : QueryBuilder.and(components.joined(separator: " && "))
    }

    private func parseDateOrSize(_ value: String, isDate: Bool, isModified: Bool) -> String {
        if isDate {
            // Value should be number of days
            if let days = Int(value) {
                return isModified ? QueryBuilder.modifiedWithinDays(days) : QueryBuilder.createdWithinDays(days)
            }
        }
        return "kMDItemFSName == \"*\"" // Fallback
    }

    private func parseSizeQuery(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var op = ">"
        var sizeStr = trimmed

        if trimmed.hasPrefix(">") {
            op = ">"
            sizeStr = String(trimmed.dropFirst())
        } else if trimmed.hasPrefix("<") {
            op = "<"
            sizeStr = String(trimmed.dropFirst())
        }

        let bytes = parseSizeString(sizeStr)
        return "kMDItemFSSize \(op) \(bytes)"
    }

    private func parseSizeString(_ str: String) -> Int64 {
        let trimmed = str.trimmingCharacters(in: .whitespaces).uppercased()
        var multiplier: Int64 = 1
        var numStr = trimmed

        if trimmed.hasSuffix("K") || trimmed.hasSuffix("KB") {
            multiplier = 1024
            numStr = trimmed.replacingOccurrences(of: "KB", with: "").replacingOccurrences(of: "K", with: "")
        } else if trimmed.hasSuffix("M") || trimmed.hasSuffix("MB") {
            multiplier = 1024 * 1024
            numStr = trimmed.replacingOccurrences(of: "MB", with: "").replacingOccurrences(of: "M", with: "")
        } else if trimmed.hasSuffix("G") || trimmed.hasSuffix("GB") {
            multiplier = 1024 * 1024 * 1024
            numStr = trimmed.replacingOccurrences(of: "GB", with: "").replacingOccurrences(of: "G", with: "")
        } else if trimmed.hasSuffix("B") {
            numStr = String(trimmed.dropLast())
        }

        return (Int64(numStr) ?? 0) * multiplier
    }

    private func formatFullResults(_ results: [SpotlightResult]) -> String {
        var lines: [String] = []
        for r in results {
            var parts = [r.path]
            if let kind = r.kind { parts.append("kind:\(kind)") }
            if let size = r.size { parts.append("size:\(size)") }
            if let mod = r.modified {
                parts.append("mod:\(ISO8601DateFormatter().string(from: mod))")
            }
            if let ct = r.contentType { parts.append("type:\(ct)") }
            lines.append(parts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    private func formatValue(_ value: Any) -> String {
        switch value {
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let array as [Any]:
            return array.map { "\($0)" }.joined(separator: ", ")
        case let num as NSNumber:
            return num.stringValue
        default:
            return "\(value)"
        }
    }
}
