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
            title: "Server snapshot",
            description:
                "Sessions, windows, panes and clients collected from separate listings, "
                + "with exact window links and no endpoint metadata.",
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
            description:
                "Every session-local window occurrence, including its exact $session:index "
                + "target, selected by a ref from list_sessions.",
            mimeType: "application/json"
        ),
        entry(
            uri: "tmux://panes/{pane}",
            name: "pane",
            title: "One pane",
            description: "What tmux reports about a pane selected by a ref from list_panes.",
            mimeType: "application/json"
        ),
        entry(
            uri: "tmux://panes/{pane}/content",
            name: "pane-content",
            title: "What a pane is showing",
            description:
                "The newest bounded slice of a pane's rendered text. Plain text, "
                + "because terminal output is neither JSON nor markup.",
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
            return Self.json(uri, JSONValue.encoding(SnapshotResult(try await server.snapshot())))
        case (1, "sessions"):
            return Self.json(
                uri,
                JSONValue.encoding(try await server.sessions().map { SessionResult($0) })
            )
        case (1, "filters"):
            return Self.json(uri, JSONValue.encoding(FilterSchema.current))
        case (3, "sessions") where parts[2] == "windows":
            let snapshot = try await server.snapshot()
            let session = try WireReferenceCodec.processLocal.resolve(
                parts[1],
                among: snapshot.sessions,
                argument: "session resource ref",
                refreshWith: "list_sessions"
            )
            let occurrences = WindowOccurrenceResult.projecting(
                snapshot.windows,
                through: snapshot.windowLinks(of: session)
            )
            return Self.json(uri, JSONValue.encoding(occurrences))
        case (2, "panes"):
            return Self.json(
                uri,
                JSONValue.encoding(PaneResult(try await requirePane(reference: parts[1])))
            )
        case (3, "panes") where parts[2] == "content":
            let pane = try await requirePane(reference: parts[1])
            let capture = try await server.captureTail(
                pane,
                includingHistory: false,
                maximumLines: PaneOutputBudget.defaultCaptureLines,
                perStreamOutputLimit: PaneOutputBudget.sourceBytes
            )
            let rows = try PaneOutputBudget.tail(
                capture.lines,
                afterDropping: capture.droppedLines
            ).lines
            return .object([
                "uri": .string(uri),
                "mimeType": .string("text/plain"),
                "text": .string(rows.joined(separator: "\n")),
            ])
        default:
            throw ToolError.unknownTool("no resource at \(uri)")
        }
    }

    private func requirePane(reference: String) async throws -> Pane {
        try WireReferenceCodec.processLocal.resolve(
            reference,
            among: try await server.panes(),
            argument: "pane resource ref",
            refreshWith: "list_panes"
        )
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
