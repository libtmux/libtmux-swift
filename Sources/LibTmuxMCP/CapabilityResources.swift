import Foundation
import LibTmux

struct CapabilityResources: Sendable {
    static let uri = "tmux://capabilities"
    static let fixed: [JSONValue] = [
        .object([
            "uri": .string(uri),
            "name": .string("capabilities"),
            "title": .string("Effective tmux MCP capabilities"),
            "description": .string(
                "The frozen tool surface, capability declarations, socket selection, and provenance."
            ),
            "mimeType": .string("application/json"),
        ])
    ]
    static let templates: [JSONValue] = []

    private let content: JSONValue

    init(tools: TmuxTools) {
        let definitions = tools.visibleDefinitions
        let rows = definitions.map(\.capabilityRow)
        let boundary: JSONValue = .object([
            "oneSocketPerProcess": .bool(true),
            "perCallSocketSelection": .bool(false),
            "hostCommandExecution": .bool(false),
            "dynamicResources": .bool(false),
        ])
        let socket: JSONValue = .object([
            "namespaceBoundary": .string("tmux-objects-only"),
            "selector": .string(tools.provenance.selector),
            "selectionProvenance": .string(tools.provenance.selectionProvenance),
            "serverState": .string(tools.provenance.serverState),
            "configurationProvenance": .string(
                tools.provenance.configurationProvenance),
        ])
        let connection: JSONValue = .object([
            "socketSelector": .string(tools.provenance.selector),
            "socketProvenance": .string(tools.provenance.selectionProvenance),
            "resolvedSocketPath": .string(
                tools.provenance.resolvedSocketPath ?? Self.socketPath(for: tools.server)),
            "serverState": .string(tools.provenance.serverState),
            "configurationProvenance": .string(
                tools.provenance.configurationProvenance),
            "attachCommand": .string(
                tools.provenance.attachCommand ?? Self.attachCommand(for: tools.server)),
        ])
        content = .object([
            "schemaVersion": .integer(1),
            "frozen": .bool(true),
            "hostCommandTools": .integer(0),
            "toolFilteringBoundary": .string("interface-shaping-not-authorization"),
            "executionAuthority": .string("tmux-user"),
            "operatingSystemBoundary": .string("none"),
            "boundary": boundary,
            "connection": connection,
            "toolCount": .integer(Int64(definitions.count)),
            "effectiveTools": .array(definitions.map(\.name).map(JSONValue.string)),
            "tools": .array(rows),
            "selection": .object([
                "toolsets": .array(
                    tools.authority.toolsets.map(\.rawValue).sorted().map(JSONValue.string)),
                "includedTools": .array(
                    tools.authority.includedTools.sorted().map(JSONValue.string)),
                "excludedTools": .array(
                    tools.authority.excludedTools.sorted().map(JSONValue.string)),
            ]),
            "socket": socket,
        ])
    }

    private static func socketPath(for server: Server) -> String {
        if case let .socketPath(path) = server.endpoint { return path }
        return ""
    }

    private static func attachCommand(for server: Server) -> String {
        let endpoint: String
        switch server.endpoint {
        case let .socketName(name): endpoint = "-L \(shellQuote(name))"
        case let .socketPath(path): endpoint = "-S \(shellQuote(path))"
        }
        return "\(shellQuote(server.tmuxExecutable)) -N \(endpoint) attach"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func read(_ requestedURI: String) throws -> JSONValue {
        guard requestedURI == Self.uri else {
            throw ToolError.unknownTool("no resource at \(requestedURI)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(content)) ?? Data("null".utf8)
        return .object([
            "uri": .string(Self.uri),
            "mimeType": .string("application/json"),
            "text": .string(String(decoding: data, as: UTF8.self)),
        ])
    }
}
