import Foundation
import LibTmux

/// The tmux tools an MCP client can call.
///
/// This is the layer that puts `LibTmux` across a process boundary, which is
/// what a filter expression was designed for: a client sends the expression as
/// data and the tool evaluates it here, rather than the client asking for
/// everything and filtering at home.
public struct TmuxTools: Sendable {
    let server: Server
    /// The highest tier a call may reach. Anything above it is hidden from
    /// `tools/list` as well as refused, so a client configured for reading is
    /// never shown a way to write.
    public let tier: SafetyTier
    /// The ceiling every wait is clamped to.
    ///
    /// What an unbounded wait costs is not the transport — calls are served
    /// concurrently — but the caller's turn: it picks the wrong pattern once
    /// and has no way to change its mind mid-call. A ceiling makes that
    /// mistake cheap and repeatable instead of terminal.
    public let waitCeiling: Duration
    let caller: CallerIdentity?

    public init(
        server: Server,
        tier: SafetyTier = .mutating,
        waitCeiling: Duration = .seconds(120),
        caller: CallerIdentity? = CallerIdentity.current()
    ) {
        self.server = server
        self.tier = tier
        self.waitCeiling = waitCeiling
        self.caller = caller
    }

    /// The tools visible at this server's tier.
    public var visibleDefinitions: [ToolDefinition] {
        Self.definitions.filter { $0.tier <= tier }
    }

    /// Runs a tool and returns its result.
    ///
    /// `progress` is how a blocking tool says it is still running. It is
    /// silent unless the client asked to be told.
    public func call(
        _ request: ToolCall,
        reporting progress: ProgressReporter = .silent
    ) async throws -> ToolOutcome {
        guard let definition = Self.byName[request.name] else {
            throw ToolError.unknownTool(request.name)
        }
        guard definition.tier <= tier else {
            throw ToolError.deniedByTier(
                request.name,
                needs: definition.tier,
                allowed: tier
            )
        }
        let arguments = try Arguments(request, for: definition)

        switch request.name {
        case "describe_server": return try await describeServer()
        case "describe_filters": return .init(FilterSchema.current)

        case "list_sessions": return try await listSessions(arguments)
        case "list_windows": return try await listWindows(arguments)
        case "list_panes": return try await listPanes(arguments)
        case "snapshot": return try await readSnapshot()
        case "capture_pane": return try await capturePane(arguments)
        case "search_panes": return try await searchPanes(arguments, progress)
        case "read_format": return try await readFormat(arguments)

        case "wait_for_output": return try await waitForOutput(arguments, progress)
        case "watch_format": return try await watchFormat(arguments, progress)
        case "wait_for_channel": return try await waitForChannel(arguments, progress)
        case "signal_channel": return try await signalChannel(arguments)

        case "run_shell": return try await runShell(arguments, progress)
        case "send_keys": return try await sendKeys(arguments)
        case "new_session": return try await newSession(arguments)
        case "new_window": return try await newWindow(arguments)
        case "split_pane": return try await splitPane(arguments)
        case "apply_workspace": return try await applyWorkspace(arguments)
        case "set_option": return try await setOption(arguments)

        case "kill_pane": return try await killPane(arguments)
        case "kill_window": return try await killWindow(arguments)
        case "kill_session": return try await killSession(arguments)

        case "run_command": return try await runCommand(arguments)
        case "run_commands": return try await runCommands(arguments)

        default: throw ToolError.unknownTool(request.name)
        }
    }

    /// Clamps a requested wait to the ceiling, and says what was enforced.
    func bounded(_ seconds: Double) -> (duration: Duration, enforced: Double) {
        let ceiling = Double(waitCeiling.components.seconds)
        let enforced = max(0.1, min(seconds, ceiling))
        return (.milliseconds(Int(enforced * 1000)), enforced)
    }

    /// Resolves a pane id to the pane, so a stale id fails with the id in the
    /// message rather than as an opaque tmux error three calls later.
    func pane(_ id: String) async throws -> Pane {
        guard let found = try await server.panes().first(where: { $0.id == id }) else {
            throw ToolError.refusedForSafety(
                "no pane \(id) on this server. Call list_panes for what is there."
            )
        }
        return found
    }

    /// Whether the caller is on this server. One tmux command, so it is only
    /// asked by the tools whose answer depends on it.
    func guardForCaller() async -> CallerGuard {
        guard caller != nil else {
            return CallerGuard(identity: nil, isSameServer: false)
        }
        let processID = try? await server.serverProcessID()
        return CallerGuard(
            identity: caller,
            isSameServer: caller?.isOn(serverProcessID: processID) ?? false
        )
    }
}

/// What a tool answers with.
///
/// Both shapes travel: `structured` is what a client that reads
/// `structuredContent` parses, and `text` is the same value as JSON for one
/// that does not. Sending only the first would make this server unusable on
/// clients that predate it.
public struct ToolOutcome: Sendable {
    public let structured: JSONValue
    public let text: String

    init(_ value: some Encodable) {
        let structured = JSONValue.encoding(value)
        self.structured = structured
        self.text = Self.render(structured)
    }

    init(structured: JSONValue) {
        self.structured = structured
        self.text = Self.render(structured)
    }

    private static func render(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
