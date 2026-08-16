import Foundation
import LibTmux

// The tools that answer questions. Nothing here changes the server.

extension TmuxTools {
    func describeServer() async throws -> ToolOutcome {
        let version = try? await server.version()
        let processID = try? await server.serverProcessID()
        let sessions = (try? await server.sessions()) ?? []
        let guardState = await guardForCaller()

        return .init(
            ServerDescription(
                endpoint: endpointDescription,
                tmuxVersion: version?.description,
                isSupported: version.map { $0 >= TmuxVersion(major: 3, minor: 2) },
                serverProcessID: processID,
                sessionCount: sessions.count,
                safetyTier: tier,
                waitCeilingSeconds: Double(waitCeiling.components.seconds),
                callerPane: guardState.ownPane,
                callerSession: guardState.isSameServer ? caller?.sessionID : nil,
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
            return .listing("sessions", project(try await server.sessions(), keeping: fields))
        }
        // A relation filter needs the related objects in hand, so this is the
        // one listing that reads a whole snapshot.
        let query = try JSONDecoder().decode(RelationQuery<Pane>.self, from: relation)
        let sessions = try await server.snapshot().sessions(ofPanes: query)
        return .listing("sessions", project(sessions, keeping: fields))
    }

    func listWindows(_ arguments: Arguments) async throws -> ToolOutcome {
        let fields = try arguments.strings("fields")
        let windows = try await server.windows()
        guard let filter = try arguments.document("filter") else {
            return .listing("windows", project(windows, keeping: fields))
        }
        let expression = try JSONDecoder().decode(FilterExpr<Window>.self, from: filter)
        return .listing("windows", project(windows.filter(expression), keeping: fields))
    }

    func listPanes(_ arguments: Arguments) async throws -> ToolOutcome {
        let fields = try arguments.strings("fields")
        let panes = try await server.panes()
        let selected: [Pane]
        if let filter = try arguments.document("filter") {
            let expression = try JSONDecoder().decode(FilterExpr<Pane>.self, from: filter)
            selected = panes.filter(expression)
        } else {
            selected = panes
        }
        // Which row is the caller's own pane, so "which pane am I in?" needs no
        // second call and killing the wrong one needs no second thought.
        let own = await guardForCaller().ownPane
        return .listing("panes", project(selected, keeping: fields, markingCaller: own))
    }

    func readSnapshot() async throws -> ToolOutcome {
        .init(try await server.snapshot())
    }

    func capturePane(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("pane")
        let pane = try await pane(target)
        let history = try arguments.bool("history", or: false)
        let maxLines = try arguments.integer("max_lines", or: 200)
        let rows = try await server.capture(pane, includingHistory: history)
        let kept = rows.suffix(max(1, maxLines))
        return .init(
            CaptureResult(
                pane: pane.id,
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
                matches.append(PaneMatch(pane: pane.id, line: offset + 1, text: line))
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
        let value =
            if let target = try arguments.optionalString("target") {
                try await server.format(template, addressing: target)
            } else {
                try await server.format(template)
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
        return .array(
            encoded.map { record in
                guard var members = record.objectValue else { return record }
                if !wanted.isEmpty {
                    members = members.filter { wanted.contains($0.key) }
                }
                if let caller, record["id"]?.stringValue == caller {
                    members["isCaller"] = .bool(true)
                }
                return .object(members)
            }
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
