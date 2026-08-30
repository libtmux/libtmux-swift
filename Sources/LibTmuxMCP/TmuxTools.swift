import Foundation
import LibTmux
import TmuxWorkspace

/// The tmux tools an MCP client can call.
///
/// This is the layer that puts `LibTmux` across a process boundary, which is
/// what a filter expression was designed for: a client sends the expression as
/// data and the tool evaluates it here, rather than the client asking for
/// everything and filtering at home.
public struct TmuxTools: Sendable {
    /// The one `run_shell` lock. See ``PaneRunCoordinator`` for why it is not
    /// per-instance; `Self.` at every use site is the reminder.
    static let paneRuns = PaneRunCoordinator()

    let server: Server
    /// The authority shared by tool listing and invocation.
    public let authority: ToolAuthority
    public var tier: SafetyTier { authority.tier }
    /// The ceiling every wait is clamped to.
    ///
    /// What an unbounded wait costs is not the transport — calls are served
    /// concurrently — but the caller's turn: it picks the wrong pattern once
    /// and has no way to change its mind mid-call. A ceiling makes that
    /// mistake cheap and repeatable instead of terminal.
    public let waitCeiling: Duration
    let caller: CallerIdentity?

    /// Creates a read-only tool set unless a higher tier is selected.
    public init(
        server: Server,
        tier: SafetyTier = .readonly,
        waitCeiling: Duration = .seconds(120),
        caller: CallerIdentity? = CallerIdentity.current()
    ) {
        self.init(
            server: server,
            authority: ToolAuthority(tier: tier),
            waitCeiling: waitCeiling,
            caller: caller
        )
    }

    /// Creates a tool set with explicit authority.
    public init(
        server: Server,
        authority: ToolAuthority,
        waitCeiling: Duration = .seconds(120),
        caller: CallerIdentity? = CallerIdentity.current()
    ) {
        self.server = server
        self.authority = authority
        self.waitCeiling = max(.zero, waitCeiling)
        self.caller = caller
    }

    /// The tools visible under this server's authority.
    public var visibleDefinitions: [ToolDefinition] {
        Self.definitions.filter { authority.rejection(for: $0) == nil }
    }

    /// Runs a tool and returns its result.
    ///
    /// `progress` is how a blocking tool says it is still running. It is
    /// silent unless the client asked to be told.
    public func call(
        _ request: ToolCall,
        reporting progress: ProgressReporter = .silent
    ) async throws(ToolError) -> ToolOutcome {
        do {
            return try await dispatch(request, reporting: progress)
        } catch let error as ToolError {
            throw error
        } catch let error as TmuxError {
            throw .tmux(error)
        } catch let error as WorkspaceBuilderError {
            throw .workspace(error)
        } catch is DecodingError {
            throw .wrongArgumentType(
                "arguments",
                expected: "values matching \(request.name)'s schema"
            )
        } catch is CancellationError {
            throw .tmux(.cancelled)
        } catch {
            if Task.isCancelled { throw .tmux(.cancelled) }
            throw .internalFailure(String(describing: error))
        }
    }

    private func dispatch(
        _ request: ToolCall,
        reporting progress: ProgressReporter
    ) async throws -> ToolOutcome {
        guard let definition = Self.byName[request.name] else {
            throw ToolError.unknownTool(request.name)
        }
        if let rejection = authority.rejection(for: definition) { throw rejection }
        let arguments = try Arguments(request, for: definition)

        return try await definition.operation.execute(
            on: self,
            arguments: arguments,
            reporting: progress
        )
    }

    /// Clamps a requested wait to the ceiling, and says what was enforced.
    func bounded(_ seconds: Double) -> (duration: Duration, enforced: Double) {
        let ceiling = max(Duration.zero, waitCeiling)
        let floor = min(Duration.milliseconds(100), ceiling)
        if seconds <= floor.secondsValue { return (floor, floor.secondsValue) }
        if seconds >= ceiling.secondsValue { return (ceiling, ceiling.secondsValue) }
        let requested = Duration.seconds(seconds)
        return (requested, requested.secondsValue)
    }

    /// Resolves an MCP pane reference to the current typed model.
    func pane(_ reference: String) async throws -> Pane {
        try WireReferenceCodec.processLocal.resolve(
            reference,
            among: try await server.panes(),
            argument: "pane",
            refreshWith: "list_panes"
        )
    }

    /// Resolves a server reference against the daemon answering now.
    func serverIncarnation(_ reference: String) async throws -> ServerIncarnation {
        let current = try await server.incarnation()
        return try WireReferenceCodec.processLocal.resolve(
            reference,
            among: [current],
            argument: "server_ref",
            refreshWith: "describe_server"
        )
    }

    /// Resolves the exact window appearance used for pane-scoped waits.
    func windowLink(for pane: Pane, matching requestedTarget: String?) async throws -> WindowLink {
        let links = try await server.windowLinks()
            .filter { $0.windowID == pane.windowID && $0.incarnation == pane.incarnation }
            .sorted { $0.target < $1.target }
        guard !links.isEmpty else {
            throw ToolError.refusedForSafety("pane \(pane.id) has gone")
        }

        if let requestedTarget {
            return try WireReferenceCodec.processLocal.resolve(
                requestedTarget,
                among: links,
                argument: "window_link",
                refreshWith: "list_windows"
            )
        }

        if links.count == 1 { return links[0] }
        let guardForCaller = try await guardForCaller()
        if guardForCaller.isSameServer, let sessionID = guardForCaller.identity?.sessionID {
            let callerLinks = links.filter { $0.sessionID == sessionID }
            if callerLinks.count == 1 { return callerLinks[0] }
        }
        throw ToolError.refusedForSafety(
            "pane \(pane.id) has several window links; pass a linkRef from list_windows"
        )
    }

    /// Whether the caller is on this server. One tmux command, so it is only
    /// asked by the tools whose answer depends on it.
    func guardForCaller() async throws -> CallerGuard {
        guard caller != nil else {
            return CallerGuard(identity: nil, isSameServer: false)
        }
        return guardForCaller(serverProcessID: try await server.serverProcessID())
    }

    func guardForCaller(serverProcessID: Int?) -> CallerGuard {
        return CallerGuard(
            identity: caller,
            isSameServer: caller?.isOn(serverProcessID: serverProcessID) ?? false
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

    /// A listing, under the name its schema promises.
    ///
    /// MCP types `structuredContent` as an object, so a bare array is not a
    /// result a validating client has to accept — and the name makes the
    /// answer say what it is without the tool's schema in hand.
    static func listing(_ name: String, _ rows: JSONValue) -> ToolOutcome {
        ToolOutcome(structured: .object([name: rows]))
    }

    private static func render(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
