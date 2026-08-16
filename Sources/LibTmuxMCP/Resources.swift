import Foundation
import LibTmux

/// The tmux hierarchy as `tmux://` URIs.
///
/// Resources are for a client that wants to *browse* rather than call: they
/// have no arguments to get wrong, and a client can attach one to a
/// conversation without the model spending a tool call. Everything here is also
/// reachable as a tool, because a model that has already decided what it wants
/// should not have to construct a URI to get it.
struct TmuxResources: Sendable {
    let server: Server

    /// Resources with a fixed URI, which a client can list and read directly.
    static let fixed: [JSONValue] = [
        entry(
            uri: "tmux://snapshot",
            name: "snapshot",
            title: "Everything at once",
            description:
                "Every session, window, pane and client as one consistent read — "
                + "the whole hierarchy without walking it.",
            mimeType: "application/json"
        ),
        entry(
            uri: "tmux://sessions",
            name: "sessions",
            title: "All sessions",
            description: "Every session on this server.",
            mimeType: "application/json"
        ),
        entry(
            uri: "tmux://filters",
            name: "filters",
            title: "Filter vocabulary",
            description:
                "The filterable fields of each object, their types and aliases — "
                + "what a `filter` argument may name.",
            mimeType: "application/json"
        ),
    ]

    /// Resources whose URI carries a target.
    static let templates: [JSONValue] = [
        entry(
            uri: "tmux://sessions/{session}/windows",
            name: "session-windows",
            title: "Windows of a session",
            description: "Every window in one session, by id or name.",
            mimeType: "application/json"
        ),
        entry(
            uri: "tmux://panes/{pane}",
            name: "pane",
            title: "One pane",
            description: "What tmux reports about a single pane.",
            mimeType: "application/json"
        ),
        entry(
            uri: "tmux://panes/{pane}/content",
            name: "pane-content",
            title: "What a pane is showing",
            description:
                "The rendered text of a pane. Plain text, because it is terminal "
                + "output — neither JSON to parse nor markup to render.",
            mimeType: "text/plain"
        ),
    ]

    func read(_ uri: String) async throws -> JSONValue {
        let path = uri.hasPrefix("tmux://") ? String(uri.dropFirst(7)) : uri
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(
            String.init
        )

        switch (parts.count, parts.first) {
        case (1, "snapshot"):
            return Self.json(uri, JSONValue.encoding(try await server.snapshot()))
        case (1, "sessions"):
            return Self.json(uri, JSONValue.encoding(try await server.sessions()))
        case (1, "filters"):
            return Self.json(uri, JSONValue.encoding(FilterSchema.current))
        case (3, "sessions") where parts[2] == "windows":
            let name = parts[1]
            let snapshot = try await server.snapshot()
            guard
                let session = snapshot.sessions.first(where: {
                    $0.id == name || $0.name == name
                })
            else { throw ToolError.unknownTool("no session \(name)") }
            return Self.json(uri, JSONValue.encoding(snapshot.windows(of: session)))
        case (2, "panes"):
            return Self.json(uri, JSONValue.encoding(try await requirePane(parts[1])))
        case (3, "panes") where parts[2] == "content":
            let pane = try await requirePane(parts[1])
            let rows = try await server.capture(pane)
            return .object([
                "uri": .string(uri),
                "mimeType": .string("text/plain"),
                "text": .string(rows.joined(separator: "\n")),
            ])
        default:
            throw ToolError.unknownTool("no resource at \(uri)")
        }
    }

    private func requirePane(_ id: String) async throws -> Pane {
        guard let pane = try await server.panes().first(where: { $0.id == id }) else {
            throw ToolError.unknownTool("no pane \(id)")
        }
        return pane
    }

    private static func json(_ uri: String, _ value: JSONValue) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
        return .object([
            "uri": .string(uri),
            "mimeType": .string("application/json"),
            "text": .string(text ?? "null"),
        ])
    }

    private static func entry(
        uri: String,
        name: String,
        title: String,
        description: String,
        mimeType: String
    ) -> JSONValue {
        .object([
            // A template's URI travels under `uriTemplate`, a fixed one's under
            // `uri`. Sending both is what lets one builder serve both lists.
            uri.contains("{") ? "uriTemplate" : "uri": .string(uri),
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "mimeType": .string(mimeType),
        ])
    }
}
