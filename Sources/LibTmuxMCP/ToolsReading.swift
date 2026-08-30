import Foundation
import LibTmux

// The tools that answer questions. Nothing here changes the server.

extension TmuxTools {
    func describeServer() async throws -> ToolOutcome {
        let before = try await server.incarnation()
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
                waitCeilingSeconds: waitCeiling.secondsValue,
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
        let snapshot = try await server.snapshot()
        let sessions = try ToolPattern.evaluate(argument: "pane_relation") {
            () throws(RegexMatchError) -> [Session] in
            try snapshot.sessions(ofPanes: query)
        }
        return .listing("sessions", project(sessions.map { SessionResult($0) }, keeping: fields))
    }

    func listWindows(_ arguments: Arguments) async throws -> ToolOutcome {
        let fields = try arguments.strings("fields")
        let snapshot = try await server.snapshot()
        let selected: [Window]
        if let filter = try arguments.document("filter") {
            let expression = try JSONDecoder().decode(FilterExpr<Window>.self, from: filter)
            try validateFilter(expression, argument: "filter")
            selected = try ToolPattern.evaluate(argument: "filter") {
                () throws(RegexMatchError) -> [Window] in
                try snapshot.windows.filter(expression)
            }
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
            selected = try ToolPattern.evaluate(argument: "filter") {
                () throws(RegexMatchError) -> [Pane] in
                try panes.filter(expression)
            }
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
        let maxLines = try arguments.integer(
            "max_lines",
            or: PaneOutputBudget.defaultCaptureLines
        )
        let capture = try await server.captureTail(
            pane,
            includingHistory: history,
            maximumLines: maxLines,
            perStreamOutputLimit: PaneOutputBudget.sourceBytes
        )
        let kept = try PaneOutputBudget.tail(
            capture.lines,
            afterDropping: capture.droppedLines
        )
        return .init(
            CaptureResult(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue,
                lines: kept.lines,
                // The end of a pane is almost always the part that matters, so
                // a cap drops the oldest rather than refusing to answer.
                droppedLines: kept.droppedLines
            )
        )
    }

    func searchPanes(
        _ arguments: Arguments,
        _ progress: ProgressReporter = .silent
    ) async throws -> ToolOutcome {
        let pattern = try arguments.string("pattern")
        let caseInsensitive = try arguments.bool("case_insensitive", or: false)
        let expression = try ToolPattern.compile(
            pattern,
            argument: "pattern",
            caseInsensitive: caseInsensitive
        )
        let matchBudget = RegexMatchBudget()
        let history = try arguments.bool("history", or: false)
        let lineLimit = try arguments.integer(
            "max_lines_per_pane",
            or: PaneOutputBudget.defaultSearchLines
        )
        let limit = try arguments.integer("max_matches", or: 50)

        var panes = try await server.panes()
        if let filter = try arguments.document("filter") {
            let predicate = try JSONDecoder().decode(FilterExpr<Pane>.self, from: filter)
            try validateFilter(predicate, argument: "filter")
            panes = try ToolPattern.evaluate(argument: "filter") {
                () throws(RegexMatchError) -> [Pane] in
                try panes.filter(predicate, regexBudget: matchBudget)
            }
        }

        var matches: [PaneMatch] = []
        var searched = 0
        var truncated = false
        var matchedBytes = 0
        paneLoop: for pane in panes {
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
            let capture = try await server.captureTail(
                pane,
                includingHistory: history,
                maximumLines: lineLimit,
                perStreamOutputLimit: PaneOutputBudget.sourceBytes
            )
            let bounded = try PaneOutputBudget.tail(
                capture.lines,
                afterDropping: capture.droppedLines
            )
            if bounded.droppedLines > 0 { truncated = true }
            for (offset, line) in bounded.lines.enumerated() {
                guard
                    try ToolPattern.matches(
                        expression,
                        in: line,
                        argument: "pattern",
                        budget: matchBudget
                    )
                else {
                    continue
                }
                guard matches.count < limit else {
                    truncated = true
                    break paneLoop
                }
                let bytes = line.utf8.count
                guard bytes <= PaneOutputBudget.returnedBytes else {
                    throw ToolError.refusedForSafety(
                        "one matching pane row exceeds the 128000-byte raw text limit"
                    )
                }
                guard matchedBytes <= PaneOutputBudget.returnedBytes - bytes else {
                    truncated = true
                    break paneLoop
                }
                matchedBytes += bytes
                matches.append(
                    PaneMatch(
                        paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                        pane: pane.id.rawValue,
                        line: bounded.droppedLines + offset + 1,
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
        let template = try ToolPattern.checkedFormat(
            try arguments.string("template"), argument: "template")
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
        let limit = try arguments.integer("max_lines", or: 200)
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
        let read = try await server.captureBounded(
            pane,
            since: cursor,
            maximumLines: limit,
            perStreamOutputLimit: PaneOutputBudget.sourceBytes
        )
        let bounded = try PaneOutputBudget.tail(
            read.lines,
            afterDropping: read.droppedLines
        )
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
                lines: bounded.lines,
                cursor: encoded,
                linesMissed: read.linesMissed,
                restarted: read.restarted,
                droppedLines: bounded.droppedLines
            )
        )
    }
}

extension TmuxTools {
    func listServers(_ arguments: Arguments) async throws -> ToolOutcome {
        let directories = try arguments.optionalStrings("directories")
        let found = try await TmuxServers.discover(
            in: directories,
            tmuxExecutable: server.tmuxExecutable
        )
        return .init(found)
    }

}
