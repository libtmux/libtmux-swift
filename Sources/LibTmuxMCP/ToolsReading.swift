import Foundation
import LibTmux

// The tools that answer questions. Nothing here changes the server.

extension TmuxTools {
    func describeServer() async throws -> ToolOutcome {
        guard let before = try await server.incarnation() else {
            throw ToolError.refusedForSafety("the tmux server is not running")
        }
        let version = try await server.version()
        let sessions = try await server.sessions()
        let after = try await server.incarnation()
        guard after == before else { throw TmuxError.serverRestarted }
        let guardState = guardForCaller(serverProcessID: before.processID)

        return .init(
            ServerDescription(
                ref: WireReferenceCodec.processLocal.reference(to: before),
                endpoint: endpointDescription,
                tmuxVersion: version.description,
                isSupported: version >= TmuxVersion(major: 3, minor: 2),
                serverProcessID: before.processID,
                sessionCount: sessions.count,
                safetyTier: tier,
                waitCeilingSeconds: Double(waitCeiling.components.seconds),
                callerPane: guardState.ownPane?.rawValue,
                callerSession: guardState.isSameServer ? caller?.sessionID?.rawValue : nil,
                capabilities: ServerDescription.Capabilities(
                    formatSubscriptions: true,
                    pushOutput: true,
                    controlModeBatching: true
                )
            )
        )
    }

    private var endpointDescription: String {
        switch server.endpoint {
        case let .socketName(name): "socket name \(name)"
        case let .socketPath(path): "socket path \(path)"
        }
    }

    func listSessions(_ arguments: Arguments) async throws -> ToolOutcome {
        let fields = try arguments.strings("fields")
        guard let relation = try arguments.document("pane_relation") else {
            let sessions = try await server.sessions().map { SessionResult($0) }
            return .listing("sessions", project(sessions, keeping: fields))
        }
        // A relation filter needs the related objects in hand, so this is the
        // one listing that reads a whole snapshot.
        let query = try JSONDecoder().decode(RelationQuery<Pane>.self, from: relation)
        try validateFilter(query.expression, argument: "pane_relation")
        let sessions = try await server.snapshot().sessions(ofPanes: query)
        return .listing("sessions", project(sessions.map { SessionResult($0) }, keeping: fields))
    }

    func listWindows(_ arguments: Arguments) async throws -> ToolOutcome {
        let fields = try arguments.strings("fields")
        let snapshot = try await server.snapshot()
        let selected: [Window]
        if let filter = try arguments.document("filter") {
            let expression = try JSONDecoder().decode(FilterExpr<Window>.self, from: filter)
            try validateFilter(expression, argument: "filter")
            selected = snapshot.windows.filter(expression)
        } else {
            selected = snapshot.windows
        }
        let occurrences = WindowOccurrenceResult.projecting(
            selected,
            through: snapshot.windowLinks
        )
        return .listing("windows", project(occurrences, keeping: fields))
    }

    func listPanes(_ arguments: Arguments) async throws -> ToolOutcome {
        let fields = try arguments.strings("fields")
        let panes = try await server.panes()
        let selected: [Pane]
        if let filter = try arguments.document("filter") {
            let expression = try JSONDecoder().decode(FilterExpr<Pane>.self, from: filter)
            try validateFilter(expression, argument: "filter")
            selected = panes.filter(expression)
        } else {
            selected = panes
        }
        // Which row is the caller's own pane, so "which pane am I in?" needs no
        // second call and killing the wrong one needs no second thought.
        let own = try await guardForCaller().ownPane?.rawValue
        return .listing(
            "panes",
            project(selected.map { PaneResult($0) }, keeping: fields, markingCaller: own)
        )
    }

    func readSnapshot() async throws -> ToolOutcome {
        .init(SnapshotResult(try await server.snapshot()))
    }

    func capturePane(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("pane")
        let pane = try WireReferenceCodec.processLocal.resolve(
            target,
            among: try await server.panes(),
            argument: "pane",
            refreshWith: "list_panes"
        )
        let history = try arguments.bool("history", or: false)
        let maxLines = try arguments.integer("max_lines", or: 200)
        let rows = try await server.capture(pane, includingHistory: history)
        let kept = rows.suffix(max(1, maxLines))
        return .init(
            CaptureResult(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue,
                lines: Array(kept),
                // The end of a pane is almost always the part that matters, so
                // a cap drops the oldest rather than refusing to answer.
                droppedLines: rows.count - kept.count
            )
        )
    }

    func searchPanes(
        _ arguments: Arguments,
        _ progress: ProgressReporter = .silent
    ) async throws -> ToolOutcome {
        let pattern = try arguments.string("pattern")
        let expression = try MatchExpression(pattern)
        let history = try arguments.bool("history", or: false)
        let limit = max(1, try arguments.integer("max_matches", or: 50))

        var panes = try await server.panes()
        if let filter = try arguments.document("filter") {
            let predicate = try JSONDecoder().decode(FilterExpr<Pane>.self, from: filter)
            try validateFilter(predicate, argument: "filter")
            panes = panes.filter(predicate)
        }

        var matches: [PaneMatch] = []
        var searched = 0
        var truncated = false
        for pane in panes {
            guard matches.count < limit else {
                truncated = true
                break
            }
            searched += 1
            // Per pane rather than on a timer: this one really does have a
            // denominator, so a client can show how far through it is.
            await progress.report(
                Double(searched),
                of: Double(panes.count),
                "searched \(searched) of \(panes.count) panes"
            )
            let rows = (try? await server.capture(pane, includingHistory: history)) ?? []
            for (offset, line) in rows.enumerated() where expression.matches(line) {
                guard matches.count < limit else {
                    truncated = true
                    break
                }
                matches.append(
                    PaneMatch(
                        paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                        pane: pane.id.rawValue,
                        line: offset + 1,
                        text: line
                    )
                )
            }
        }
        return .init(
            SearchResult(
                matches: matches,
                panesSearched: searched,
                panesAvailable: panes.count,
                truncated: truncated
            )
        )
    }

    func readFormat(_ arguments: Arguments) async throws -> ToolOutcome {
        let template = try arguments.string("template")
        guard let target = try arguments.optionalString("target") else {
            return .init(FormatResult(value: try await server.format(template)))
        }

        let references = WireReferenceCodec.processLocal
        let snapshot = try await server.snapshot()
        let value: String?
        switch try references.checkedKind(
            of: target,
            argument: "target",
            refreshWith: "a hierarchy listing"
        ) {
        case .session:
            let session = try references.resolve(
                target,
                among: snapshot.sessions,
                argument: "target",
                refreshWith: "list_sessions"
            )
            value = try await server.format(template, for: session)
        case .windowLink:
            let link = try references.resolve(
                target,
                among: snapshot.windowLinks,
                argument: "target",
                refreshWith: "list_windows"
            )
            value = try await server.format(template, for: link)
        case .pane:
            let pane = try references.resolve(
                target,
                among: snapshot.panes,
                argument: "target",
                refreshWith: "list_panes"
            )
            let links = snapshot.windowLinks.filter {
                $0.windowID == pane.windowID && $0.incarnation == pane.incarnation
            }
            let link: WindowLink
            if let linkReference = try arguments.optionalString("window_link") {
                link = try references.resolve(
                    linkReference,
                    among: links,
                    argument: "window_link",
                    refreshWith: "list_windows"
                )
            } else if links.count == 1, let only = links.first {
                link = only
            } else {
                throw ToolError.refusedForSafety(
                    "the pane has several window links; pass a linkRef from list_windows"
                )
            }
            value = try await server.format(template, for: pane, through: link)
        case .window:
            throw ToolError.wrongArgumentType(
                "target",
                expected: "a session, window-link, or pane ref; use linkRef for a window context"
            )
        case .server:
            throw ToolError.wrongArgumentType(
                "target",
                expected: "no target for a server format"
            )
        case .client:
            throw ToolError.wrongArgumentType(
                "target",
                expected: "a session, window-link, or pane ref; client formats are not supported"
            )
        }
        return .init(FormatResult(value: value))
    }

    /// Encodes records, optionally keeping only the named fields.
    ///
    /// Projection happens here rather than in tmux because the fields a client
    /// names are this library's, not tmux's — the listings are one command
    /// whatever is asked for, so this saves the caller's context rather than a
    /// round trip.
    func project(
        _ records: [some Encodable],
        keeping fields: [String],
        markingCaller caller: String? = nil
    ) -> JSONValue {
        let encoded = records.map { JSONValue.encoding($0) }
        guard !fields.isEmpty || caller != nil else { return .array(encoded) }
        let wanted = Set(fields)
        let references = Set(["ref", "windowRef", "linkRef"])
        return .array(
            encoded.map { record in
                guard var members = record.objectValue else { return record }
                if !wanted.isEmpty {
                    members = members.filter {
                        wanted.contains($0.key) || references.contains($0.key)
                    }
                }
                if let caller, record["id"]?.stringValue == caller {
                    members["isCaller"] = .bool(true)
                }
                return .object(members)
            }
        )
    }
}

private func validateFilter<Root: Filterable>(
    _ expression: FilterExpr<Root>,
    argument: String
) throws {
    do {
        try expression.validate()
    } catch FilterValidationError.unknownField(let field) {
        throw ToolError.wrongArgumentType(
            argument,
            expected: "a filter using known field ids; \(field) is unknown"
        )
    } catch FilterValidationError.incompatibleOperation(let field, let type, _) {
        throw ToolError.wrongArgumentType(
            argument,
            expected: "a filter whose operator and values match \(field)'s \(type.rawValue) type"
        )
    } catch FilterValidationError.invalidRegularExpression(let field, _) {
        throw ToolError.wrongArgumentType(
            argument,
            expected: "a filter with a usable regular expression for \(field)"
        )
    }
}

/// A compiled search pattern, so an unusable one is reported when it is given
/// rather than quietly matching nothing on every line.
struct MatchExpression {
    private let expression: NSRegularExpression

    init(_ pattern: String) throws {
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ToolError.wrongArgumentType(
                "pattern",
                expected: "a usable regular expression"
            )
        }
    }

    func matches(_ line: String) -> Bool {
        expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            != nil
    }
}

extension TmuxTools {
    func captureSince(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try WireReferenceCodec.processLocal.resolve(
            try arguments.string("pane"),
            among: try await server.panes(),
            argument: "pane",
            refreshWith: "list_panes"
        )
        let limit = max(1, try arguments.integer("max_lines", or: 200))
        var cursor: CaptureCursor?
        if let text = try arguments.optionalString("cursor") {
            // A cursor the caller mangled is not worth guessing at: starting
            // over is honest and costs one empty answer, where reading a wrong
            // anchor would report rows that were never there.
            cursor = try? JSONDecoder().decode(CaptureCursor.self, from: Data(text.utf8))
            guard cursor != nil else {
                throw ToolError.wrongArgumentType(
                    "cursor",
                    expected: "a cursor a previous capture_since returned"
                )
            }
        }
        let read = try await server.capture(pane, since: cursor, limit: limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(
            decoding: (try? encoder.encode(read.cursor)) ?? Data(),
            as: UTF8.self
        )
        return .init(
            CaptureSinceResult(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue,
                lines: read.lines,
                cursor: encoded,
                linesMissed: read.linesMissed,
                restarted: read.restarted
            )
        )
    }
}

extension TmuxTools {
    func listServers(_ arguments: Arguments) async throws -> ToolOutcome {
        let directories = try arguments.optionalStrings("directories")
        let found = await TmuxServers.discover(
            in: directories,
            tmuxExecutable: server.tmuxExecutable
        )
        return .listing("servers", JSONValue.encoding(found))
    }

    func showOptions(_ arguments: Arguments) async throws -> ToolOutcome {
        let scope: OptionScope =
            switch try arguments.string("scope", or: "server") {
            case "session": .session
            case "window": .window
            case "pane": .pane
            default: .server
            }
        let global = try arguments.bool("global", or: false)
        let listed = try await server.options(scope, global: global)
        let selected =
            if let name = try arguments.optionalString("name") {
                listed.filter { $0.name == name }
            } else {
                listed
            }
        return .listing(
            "options",
            .array(
                selected.map {
                    .object(["name": .string($0.name), "value": .string($0.value)])
                }
            )
        )
    }

    func showEnvironment(_ arguments: Arguments) async throws -> ToolOutcome {
        let variables = try await server.environment(.global)
        return .listing(
            "variables",
            .array(
                variables.map { variable in
                    .object([
                        "name": .string(variable.name),
                        "value": variable.value.map(JSONValue.string) ?? .null,
                    ])
                }
            )
        )
    }

    func showHooks(_ arguments: Arguments) async throws -> ToolOutcome {
        let hooks = try await server.hooks(.global)
        return .listing(
            "hooks",
            .array(
                hooks.map { hook in
                    .object([
                        "name": .string(hook.name),
                        "index": .number(Double(hook.index)),
                        "command": .string(hook.command),
                    ])
                }
            )
        )
    }

}
