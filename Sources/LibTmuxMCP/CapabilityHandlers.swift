import Foundation
import LibTmux

struct ReadBatchAccumulator {
    /// Leaves room for the JSON-RPC envelope and the concise text fallback.
    static let maximumBytes = 900_000

    private struct Row {
        let index: Int
        let tool: String
        let success: Bool
        let error: String?
        var result: JSONValue?
        var resultTruncated = false

        var value: JSONValue {
            .object([
                "index": .integer(Int64(index)),
                "tool": .string(tool),
                "success": .bool(success),
                "error": error.map(JSONValue.string) ?? .null,
                "result": result ?? .null,
                "resultTruncated": .bool(resultTruncated),
            ])
        }
    }

    private let total: Int
    private let onError: String
    private var rows: [Row] = []
    private var succeeded = 0
    private var failed = 0
    private var stoppedAt: Int?
    private var truncated = false
    private var truncatedBytes = 0

    init(total: Int, onError: String = "stop") {
        self.total = total
        self.onError = onError
    }

    mutating func append(tool: String, outcome: ToolOutcome) -> Bool {
        precondition(rows.count < total)
        let index = rows.count
        succeeded += 1
        rows.append(
            Row(
                index: index,
                tool: tool,
                success: true,
                error: nil,
                result: .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(outcome.text)])
                    ]),
                    "structuredContent": outcome.structured,
                    "isError": .bool(false),
                ])
            ))
        enforceLimit()
        return true
    }

    mutating func append(tool: String, error: String) -> Bool {
        precondition(rows.count < total)
        let index = rows.count
        failed += 1
        rows.append(
            Row(
                index: index,
                tool: tool,
                success: false,
                error: error,
                result: .object([
                    "content": .array([
                        .object(["type": .string("text"), "text": .string(error)])
                    ]),
                    "structuredContent": .null,
                    "isError": .bool(true),
                ])
            ))
        if onError == "stop" { stoppedAt = index }
        enforceLimit()
        return onError == "continue"
    }

    func finish() -> JSONValue {
        value()
    }

    func finishOutcome() -> ToolOutcome {
        let suffix = truncated ? "; nested result bytes were truncated" : ""
        return ToolOutcome(
            structured: value(),
            text: "Read batch completed: \(succeeded) succeeded, \(failed) failed\(suffix)."
        )
    }

    private mutating func enforceLimit() {
        while encodedSize(of: value()) > Self.maximumBytes {
            guard let candidate = rows.indices.last(where: { rows[$0].result != nil }) else {
                preconditionFailure("read batch metadata exceeds its protocol budget")
            }
            let fullSize = encodedSize(of: rows[candidate].result ?? .null)
            rows[candidate].result = nil
            rows[candidate].resultTruncated = true
            let compactSize = encodedSize(of: JSONValue.null)
            truncatedBytes += max(0, fullSize - compactSize)
            truncated = true
        }
    }

    private func value() -> JSONValue {
        .object([
            "results": .array(rows.map(\.value)),
            "onError": .string(onError),
            "succeeded": .integer(Int64(succeeded)),
            "failed": .integer(Int64(failed)),
            "stoppedAt": stoppedAt.map { .integer(Int64($0)) } ?? .null,
            "truncated": .bool(truncated),
            "truncatedBytes": .integer(Int64(truncatedBytes)),
        ])
    }

    private func encodedSize(of value: JSONValue) -> Int {
        (try? JSONEncoder().encode(value).count) ?? .max
    }

    /// Rolls back only complete nested results until the complete JSON-RPC
    /// response fits. Row metadata remains, so partial execution is explicit.
    static func bounding(
        _ outcome: ToolOutcome,
        whileExceeding fits: (ToolOutcome) -> Bool
    ) -> ToolOutcome? {
        guard var batch = outcome.structured.objectValue,
            var rows = batch["results"]?.arrayValue,
            batch["onError"]?.stringValue != nil,
            batch["truncated"]?.boolValue != nil,
            batch["truncatedBytes"]?.intValue != nil
        else { return nil }
        var candidate = outcome
        while !fits(candidate) {
            guard
                let index = rows.indices.reversed().first(where: {
                    rows[$0]["result"]?.isNull == false
                }),
                var row = rows[index].objectValue,
                let result = row["result"]
            else { return nil }
            let removed = max(0, encodedSize(result) - encodedSize(.null))
            row["result"] = .null
            row["resultTruncated"] = .bool(true)
            rows[index] = .object(row)
            batch["results"] = .array(rows)
            batch["truncated"] = .bool(true)
            batch["truncatedBytes"] = .integer(
                Int64((batch["truncatedBytes"]?.intValue ?? 0) + removed)
            )
            let text: String
            if outcome.text.contains("nested result bytes were truncated") {
                text = outcome.text
            } else {
                let stem =
                    outcome.text.last == "." ? outcome.text.dropLast() : Substring(outcome.text)
                text = "\(stem); nested result bytes were truncated."
            }
            candidate = ToolOutcome(structured: .object(batch), text: text)
        }
        return candidate
    }

    private static func encodedSize(_ value: JSONValue) -> Int {
        (try? JSONEncoder().encode(value).count) ?? .max
    }
}

extension TmuxTools {
    func capabilitySession(_ requested: String) async throws -> Session {
        // Ask tmux for the one session rather than every session: a client
        // naming a session by id or by name is the common path, and the whole
        // listing is only needed for the wire-reference fallback below.
        if let id = SessionID(rawValue: requested),
            let found = try await server.session(id)
        {
            return found
        }
        if let found = try await server.session(named: requested) { return found }
        return try WireReferenceCodec.processLocal.resolve(
            requested,
            among: try await server.sessions(),
            argument: "session",
            refreshWith: "list_sessions"
        )
    }

    func capabilityWindow(_ requested: String) async throws -> Window {
        if let id = WindowID(rawValue: requested), let found = try await server.window(id) {
            return found
        }
        return try WireReferenceCodec.processLocal.resolve(
            requested,
            among: try await server.windows(),
            argument: "windowId",
            refreshWith: "list_windows"
        )
    }

    func capabilityPane(_ requested: String) async throws -> Pane {
        if let id = PaneID(rawValue: requested), let found = try await server.pane(id) {
            return found
        }
        return try WireReferenceCodec.processLocal.resolve(
            requested,
            among: try await server.panes(),
            argument: "paneId",
            refreshWith: "list_panes"
        )
    }

    func capabilityListSessions() async throws -> ToolOutcome {
        .listing(
            "sessions",
            .array(
                try await server.sessions().map {
                    JSONValue.encoding(SessionResult($0))
                }))
    }

    func capabilityListWindows(_ arguments: Arguments) async throws -> ToolOutcome {
        let snapshot = try await server.snapshot()
        var links = snapshot.windowLinks
        if let requested = try arguments.optionalString("session") {
            let session = try await capabilitySession(requested)
            links = links.filter { $0.sessionID == session.id }
        }
        let rows = WindowOccurrenceResult.projecting(snapshot.windows, through: links)
        return .listing("windows", .array(rows.map(JSONValue.encoding)))
    }

    func capabilityListPanes(_ arguments: Arguments) async throws -> ToolOutcome {
        let snapshot = try await server.snapshot()
        var panes = snapshot.panes
        if let requested = try arguments.optionalString("window") {
            let window = try await capabilityWindow(requested)
            panes = panes.filter { $0.windowID == window.id }
        }
        if let requested = try arguments.optionalString("session") {
            let session = try await capabilitySession(requested)
            let windowIDs = Set(
                snapshot.windowLinks.filter { $0.sessionID == session.id }.map(\.windowID))
            panes = panes.filter { windowIDs.contains($0.windowID) }
        }
        return .listing("panes", .array(panes.map { JSONValue.encoding(PaneResult($0)) }))
    }

    func getServerInfo() async throws -> ToolOutcome {
        let running = try await server.isRunning()
        var result: [String: JSONValue] = ["running": .bool(running)]
        if let version = try? await server.version() {
            result["version"] = .string(version.description)
        }
        if running, let socket = try await server.format("#{socket_path}") {
            result["socketPath"] = .string(socket)
        }
        return .init(structured: .object(result))
    }

    func getSessionInfo(_ arguments: Arguments) async throws -> ToolOutcome {
        let session = try await capabilitySession(try arguments.string("session"))
        return .init(structured: .object(["session": JSONValue.encoding(SessionResult(session))]))
    }

    func getWindowInfo(_ arguments: Arguments) async throws -> ToolOutcome {
        let requested = try arguments.string("windowId")
        let snapshot = try await server.snapshot()
        let window = try await capabilityWindow(requested)
        let links = snapshot.windowLinks.filter { $0.windowID == window.id }
        return .init(
            structured: .object([
                "window": JSONValue.encoding(WindowResult(window)),
                "placements": .array(links.map { JSONValue.encoding(WindowLinkResult($0)) }),
            ]))
    }

    func getPaneInfo(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        return .init(structured: .object(["pane": JSONValue.encoding(PaneResult(pane))]))
    }

    func findPaneByPosition(_ arguments: Arguments) async throws -> ToolOutcome {
        let window = try await capabilityWindow(try arguments.string("windowId"))
        let corner = try arguments.string("corner")
        let pane = try requirePane(
            try await server.panes().first { candidate in
                guard candidate.windowID == window.id else { return false }
                return switch corner {
                case "top-left": candidate.isAtTop && candidate.isAtLeft
                case "top-right": candidate.isAtTop && candidate.isAtRight
                case "bottom-left": candidate.isAtBottom && candidate.isAtLeft
                default: candidate.isAtBottom && candidate.isAtRight
                }
            }
        )
        return .init(structured: .object(["pane": JSONValue.encoding(PaneResult(pane))]))
    }

    private func requirePane(_ pane: Pane?) throws -> Pane {
        guard let pane else { throw ToolError.refusedForSafety("no pane occupies that corner") }
        return pane
    }

    func getTmuxVariables(_ arguments: Arguments) async throws -> ToolOutcome {
        let names = try arguments.strings("names")
        guard !names.isEmpty else { throw ToolError.missingArgument("names") }
        let allowed = try NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_]*$")
        for name in names {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard allowed.firstMatch(in: name, range: range)?.range == range else {
                throw ToolError.wrongArgumentType(
                    "names", expected: "validated tmux variable names")
            }
        }
        let paneID = try arguments.optionalString("paneId")
        var values: [String: JSONValue] = [:]
        for name in names {
            let format = "#{\(name)}"
            let value =
                if let paneID {
                    try await server.format(
                        format,
                        addressing: (try await capabilityPane(paneID)).id.rawValue
                    )
                } else {
                    try await server.format(format)
                }
            values[name] = value.map(JSONValue.string) ?? .null
        }
        return .init(structured: .object(["values": .object(values)]))
    }

    func capabilityCapturePane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        let maximum = max(1, try arguments.integer("maxLines", or: 200))
        let capture = try await server.captureRange(
            pane,
            startingAt: try arguments.optionalInteger("start"),
            endingAt: try arguments.optionalInteger("end"),
            joiningWrappedLines: try arguments.bool("joinWrapped", or: false),
            maximumLines: maximum
        )
        return .init(
            structured: .object([
                "paneId": .string(pane.id.rawValue),
                "lines": .array(capture.lines.map(JSONValue.string)),
                "droppedLines": .integer(Int64(capture.droppedLines)),
            ]))
    }

    func capabilityCaptureSince(_ arguments: Arguments) async throws -> ToolOutcome {
        try await captureSince(arguments)
    }

    func snapshotPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let info = try await getPaneInfo(arguments)
        let capture = try await capabilityCapturePane(arguments)
        return .init(
            structured: .object([
                "pane": info.structured["pane"] ?? .null,
                "capture": capture.structured,
            ]))
    }

    func capabilitySearchPanes(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        try await searchPanes(arguments, progress)
    }

    func capabilityShowEnvironment(_ arguments: Arguments) async throws -> ToolOutcome {
        let scope: EnvironmentScope =
            if let session = try arguments.optionalString("session") {
                .session((try await capabilitySession(session)).id.rawValue)
            } else {
                .global
            }
        let values = try await server.environment(scope)
        return .init(
            structured: .object([
                "environment": .object(
                    Dictionary(
                        uniqueKeysWithValues: values.map {
                            ($0.name, $0.value.map(JSONValue.string) ?? .null)
                        }))
            ]))
    }

    func capabilityShowHooks(_ arguments: Arguments) async throws -> ToolOutcome {
        let scope: HookScope =
            if let session = try arguments.optionalString("session") {
                .session((try await capabilitySession(session)).id.rawValue)
            } else {
                .global
            }
        let hooks = try await server.hooks(scope)
        return .listing(
            "hooks",
            .array(
                hooks.map { hook in
                    .object([
                        "name": .string(hook.name),
                        "index": .integer(Int64(hook.index)),
                        "command": .string(hook.command),
                    ])
                }))
    }

    func capabilityShowOption(_ arguments: Arguments) async throws -> ToolOutcome {
        try await showOptions(arguments)
    }

    func waitForText(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        try await waitForOutput(arguments, progress)
    }

    func callReadToolsBatch(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        let operations = try arguments.array("operations")
        guard 1...16 ~= operations.count else {
            throw ToolError.wrongArgumentType("operations", expected: "one through 16 calls")
        }
        let allowed =
            visibleDefinitions.first { $0.name == "call_read_tools_batch" }?
            .nestedAuthority ?? []
        let onError = try arguments.string("onError", or: "stop")
        var batch = ReadBatchAccumulator(total: operations.count, onError: onError)
        for operation in operations {
            guard let object = operation.objectValue else {
                throw ToolError.wrongArgumentType("operations", expected: "objects")
            }
            let accepted = Set(["arguments", "tool"])
            let unknown = object.keys.filter { !accepted.contains($0) }.sorted()
            guard unknown.isEmpty else {
                throw ToolError.unknownArguments(unknown, accepted: accepted.sorted())
            }
            guard let name = object["tool"]?.stringValue, allowed.contains(name) else {
                throw ToolError.refusedForSafety("batch operation is outside nested authority")
            }
            let nestedArguments = object["arguments"] ?? .object([:])
            guard nestedArguments.objectValue != nil else {
                throw ToolError.wrongArgumentType("arguments", expected: "an object")
            }
            let call = ToolCall(name: name, arguments: nestedArguments)
            do {
                let result = try await self.callNested(call, reporting: progress)
                if !batch.append(tool: name, outcome: result) { break }
            } catch {
                if !batch.append(tool: name, error: String(describing: error)) { break }
            }
        }
        return batch.finishOutcome()
    }

    func renameSession(_ arguments: Arguments) async throws -> ToolOutcome {
        let session = try await capabilitySession(try arguments.string("session"))
        let name = try arguments.string("name")
        try await server.rename(session, to: name)
        return .init(
            structured: .object(["sessionId": .string(session.id.rawValue), "name": .string(name)]))
    }

    func renameWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let window = try await capabilityWindow(try arguments.string("windowId"))
        let name = try arguments.string("name")
        try await server.rename(window, to: name)
        return .init(
            structured: .object(["windowId": .string(window.id.rawValue), "name": .string(name)]))
    }

    func selectPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        try await server.select(pane)
        return .init(structured: .object(["paneId": .string(pane.id.rawValue)]))
    }

    private func windowLink(
        for window: Window,
        sourceSession: String?,
        sourceIndex: Int?
    ) async throws -> WindowLink {
        var links = try await server.windowLinks().filter { $0.windowID == window.id }
        if let sourceSession {
            let session = try await capabilitySession(sourceSession)
            links = links.filter { $0.sessionID == session.id }
        }
        if let sourceIndex { links = links.filter { $0.index == sourceIndex } }
        guard links.count == 1, let link = links.first else {
            throw ToolError.refusedForSafety("window needs one exact session-local appearance")
        }
        return link
    }

    func selectWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let window = try await capabilityWindow(try arguments.string("windowId"))
        let link = try await windowLink(
            for: window,
            sourceSession: try arguments.optionalString("sourceSession"),
            sourceIndex: try arguments.optionalInteger("sourceIndex")
        )
        try await server.select(link)
        return .init(
            structured: .object([
                "windowId": .string(window.id.rawValue), "target": .string(link.target),
            ]))
    }

    func moveWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let window = try await capabilityWindow(try arguments.string("windowId"))
        let source = try await windowLink(
            for: window,
            sourceSession: try arguments.optionalString("sourceSession"),
            sourceIndex: try arguments.optionalInteger("sourceIndex")
        )
        let destination = try await capabilitySession(
            try arguments.optionalString("session") ?? source.sessionID.rawValue
        )
        let moved = try await server.move(
            source,
            to: destination,
            at: try arguments.optionalInteger("index")
        )
        return .init(
            structured: .object([
                "windowId": .string(window.id.rawValue), "target": .string(moved.target),
            ]))
    }

    func swapPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        let other = try await capabilityPane(try arguments.string("otherPaneId"))
        try await server.swap(pane, with: other)
        return .init(
            structured: .object([
                "paneId": .string(pane.id.rawValue), "otherPaneId": .string(other.id.rawValue),
            ]))
    }

    func capabilityResizePane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        if try arguments.bool("zoom", or: false) {
            try await server.toggleZoom(pane)
        } else if let direction = try arguments.optionalString("direction") {
            let resolved: ResizeDirection =
                switch direction {
                case "up": .up
                case "down": .down
                case "left": .left
                default: .right
                }
            try await server.resize(
                pane, by: try arguments.integer("amount", or: 1), toward: resolved)
        } else {
            let width = try arguments.optionalInteger("width")
            let height = try arguments.optionalInteger("height")
            guard width != nil || height != nil else {
                throw ToolError.missingArgument("width, height, or direction")
            }
            try await server.resize(pane, width: width, height: height)
        }
        return .init(structured: .object(["paneId": .string(pane.id.rawValue)]))
    }

    func resizeWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let window = try await capabilityWindow(try arguments.string("windowId"))
        var values = ["-t", window.id.rawValue]
        if let width = try arguments.optionalInteger("width") { values += ["-x", String(width)] }
        if let height = try arguments.optionalInteger("height") {
            values += ["-y", String(height)]
        }
        guard values.count > 2 else { throw ToolError.missingArgument("width or height") }
        let reply = try await server.run(TmuxCommand("resize-window", values))
        guard reply.isSuccess else { throw ToolError.tmuxRejected(reply.errorText) }
        return .init(structured: .object(["windowId": .string(window.id.rawValue)]))
    }

    func capabilitySelectLayout(_ arguments: Arguments) async throws -> ToolOutcome {
        let window = try await capabilityWindow(try arguments.string("windowId"))
        let layout = try arguments.string("layout")
        try await server.selectLayout(window, layout)
        return .init(
            structured: .object([
                "windowId": .string(window.id.rawValue), "layout": .string(layout),
            ]))
    }

    func setHistoryLimit(_ arguments: Arguments) async throws -> ToolOutcome {
        let lines = try arguments.integer("lines", or: 0)
        let reply = try await server.setOption(
            "history-limit", to: String(lines), scope: .globalSession)
        guard reply.isSuccess else { throw ToolError.tmuxRejected(reply.errorText) }
        return .init(structured: .object(["lines": .integer(Int64(lines))]))
    }

    func setMouseEnabled(_ arguments: Arguments) async throws -> ToolOutcome {
        let enabled = try arguments.bool("enabled", or: false)
        let reply = try await server.setOption(
            "mouse", to: enabled ? "on" : "off", scope: .globalSession)
        guard reply.isSuccess else { throw ToolError.tmuxRejected(reply.errorText) }
        return .init(structured: .object(["enabled": .bool(enabled)]))
    }

    func setPaneTitle(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        let title = try arguments.string("title")
        try await server.setTitle(title, of: pane)
        return .init(
            structured: .object(["paneId": .string(pane.id.rawValue), "title": .string(title)]))
    }

    func capabilityWaitForChannel(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        try await waitForChannel(arguments, progress)
    }

    func capabilitySignalChannel(_ arguments: Arguments) async throws -> ToolOutcome {
        try await signalChannel(arguments)
    }

    func createSession(_ arguments: Arguments) async throws -> ToolOutcome {
        try await newSession(arguments)
    }

    func createWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("session")
        let session = try await capabilitySession(target)
        let appearance = try await server.newWindow(
            in: session,
            named: try arguments.optionalString("name"),
            startDirectory: try arguments.optionalString("startDirectory")
        )
        return .init(WindowOccurrenceResult(window: appearance.window, link: appearance.link))
    }

    func createSplit(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        let direction: PaneDirection =
            switch try arguments.string("direction", or: "below") {
            case "right": .right
            case "left": .left
            case "above": .above
            default: .below
            }
        let created = try await server.split(
            pane,
            direction: direction,
            startDirectory: try arguments.optionalString("startDirectory")
        )
        return .init(PaneResult(created))
    }

    func runShellCommand(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        try await runShell(arguments, progress)
    }

    func capabilitySendKeys(_ arguments: Arguments) async throws -> ToolOutcome {
        let requested = try arguments.string("paneId")
        var keys = try arguments.strings("keys")
        guard !keys.isEmpty else { throw ToolError.missingArgument("keys") }
        if try arguments.bool("enter", or: false) { keys.append("Enter") }
        let force = try arguments.bool("force", or: false)
        let literal = try arguments.bool("literal", or: false)
        let initial = try await preflightPaneInput(
            requested,
            scope: .configuredCohort,
            force: force,
            operation: "send_keys"
        )
        let reservation = try await Self.reservePaneInput(initial, operation: "send_keys")
        let final: PaneInputResolution
        do {
            final = try await preflightPaneInput(
                requested,
                scope: .configuredCohort,
                force: force,
                transitionFrom: initial,
                reservation: reservation,
                operation: "send_keys"
            )
            try await server.sendKeys(keys, to: final.source, literally: literal)
        } catch {
            await Self.paneRuns.release(reservation)
            throw error
        }
        await Self.paneRuns.release(reservation)
        return .init(
            SentKeys(
                paneRef: WireReferenceCodec.processLocal.reference(to: final.source),
                pane: final.source.id.rawValue,
                keys: keys,
                resolvedPaneIds: final.configuredPaneIDs.map(\.rawValue)
            ))
    }

    func sendKeysBatch(_ arguments: Arguments) async throws -> ToolOutcome {
        let operations = try arguments.array("operations")
        let continueOnError = try arguments.string("onError", or: "stop") == "continue"
        var completed = 0
        var failures: [JSONValue] = []
        var targets: [JSONValue] = []
        for (index, operation) in operations.enumerated() {
            guard let object = operation.objectValue else {
                throw ToolError.wrongArgumentType("operations", expected: "objects")
            }
            do {
                guard let definition = Self.byName["send_keys"] else {
                    throw ToolError.internalFailure("send_keys definition is unavailable")
                }
                let nestedArguments = try Arguments(
                    ToolCall(name: "send_keys", arguments: .object(object)),
                    for: definition
                )
                let result = try await capabilitySendKeys(nestedArguments)
                targets.append(
                    .object([
                        "index": .integer(Int64(index)),
                        "resolvedPaneIds": result.structured["resolvedPaneIds"] ?? .array([]),
                    ]))
                completed += 1
            } catch {
                failures.append(
                    .object([
                        "index": .integer(Int64(index)),
                        "reason": .string(String(describing: error)),
                    ]))
                if !continueOnError { break }
            }
        }
        return .init(
            structured: .object([
                "completed": .integer(Int64(completed)), "failures": .array(failures),
                "targets": .array(targets),
            ]))
    }

    func capabilityPasteText(_ arguments: Arguments) async throws -> ToolOutcome {
        try await pasteText(arguments)
    }

    func capabilityRespawnPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        let killFirst = try arguments.bool("killFirst", or: false)
        let force = try arguments.bool("force", or: false)
        try await server.respawn(
            pane,
            killingExisting: killFirst || force,
            startDirectory: try arguments.optionalString("startDirectory")
        )
        return .init(
            Respawned(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue
            ))
    }

    func setSynchronizePanes(_ arguments: Arguments) async throws -> ToolOutcome {
        let window = try await capabilityWindow(try arguments.string("windowId"))
        let enabled = try arguments.bool("enabled", or: false)
        let reply = try await server.setOption(
            "synchronize-panes",
            to: enabled ? "on" : "off",
            scope: .window(window)
        )
        guard reply.isSuccess else { throw ToolError.tmuxRejected(reply.errorText) }
        return .init(
            structured: .object([
                "windowId": .string(window.id.rawValue), "enabled": .bool(enabled),
            ]))
    }

    func clearPaneScrollback(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        try await server.clearHistory(pane)
        return .init(
            structured: .object(["paneId": .string(pane.id.rawValue), "deleted": .bool(true)]))
    }

    func capabilityKillPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        try await guardForCaller().checkPane(
            pane.id, override: try arguments.bool("force", or: false))
        try await server.kill(pane)
        return .init(
            structured: .object(["paneId": .string(pane.id.rawValue), "deleted": .bool(true)]))
    }

    func capabilityKillWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let window = try await capabilityWindow(try arguments.string("windowId"))
        try await guardForCaller().checkWindow(
            window.id, override: try arguments.bool("force", or: false))
        try await server.kill(window)
        return .init(
            structured: .object(["windowId": .string(window.id.rawValue), "deleted": .bool(true)]))
    }

    func capabilityKillSession(_ arguments: Arguments) async throws -> ToolOutcome {
        let session = try await capabilitySession(try arguments.string("session"))
        try await guardForCaller().checkSession(
            session.id, override: try arguments.bool("force", or: false))
        try await server.kill(session)
        return .init(
            structured: .object(["sessionId": .string(session.id.rawValue), "deleted": .bool(true)])
        )
    }
}
