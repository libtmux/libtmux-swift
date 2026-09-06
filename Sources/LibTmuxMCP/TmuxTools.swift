import Foundation
import LibTmux

/// The tmux tools an MCP client can call.
///
/// This is the layer that puts `LibTmux` across a process boundary, which is
/// what a filter expression was designed for: a client sends the expression as
/// data and the tool evaluates it here, rather than the client asking for
/// everything and filtering at home.
public struct TmuxTools: Sendable {
    /// The one `run_shell_command` lock. See ``PaneRunCoordinator`` for why it is not
    /// per-instance; `Self.` at every use site is the reminder.
    static let paneRuns = PaneRunCoordinator()

    let server: Server
    /// The authority shared by tool listing and invocation.
    public let authority: ToolAuthority
    /// The ceiling every wait is clamped to.
    ///
    /// What an unbounded wait costs is not the transport — calls are served
    /// concurrently — but the caller's turn: it picks the wrong pattern once
    /// and has no way to change its mind mid-call. A ceiling makes that
    /// mistake cheap and repeatable instead of terminal.
    public let waitCeiling: Duration
    let caller: CallerIdentity?
    private let resolvedDefinitions: [ToolDefinition]
    private let resolvedByName: [String: ToolDefinition]
    private let callableByName: [String: ToolDefinition]
    public let provenance: ServerProvenance

    /// Creates a tool set with explicit authority.
    public init(
        server: Server,
        authority: ToolAuthority = ToolAuthority(toolsets: [.inspect]),
        waitCeiling: Duration = .seconds(120),
        caller: CallerIdentity? = CallerIdentity.current(),
        provenance: ServerProvenance = .unknown
    ) {
        self.server = server
        self.authority = authority
        self.waitCeiling = max(.zero, waitCeiling)
        self.caller = caller
        let resolved = authority.resolve(Self.definitions)
        self.resolvedDefinitions = resolved
        self.resolvedByName = Dictionary(uniqueKeysWithValues: resolved.map { ($0.name, $0) })
        let callableNames = Set(
            resolved.flatMap { [$0.name] + Array($0.nestedAuthority) }
        )
        self.callableByName = Self.byName.filter { callableNames.contains($0.key) }
        self.provenance = provenance
    }

    /// The tools visible under this server's authority.
    public var visibleDefinitions: [ToolDefinition] {
        resolvedDefinitions
    }

    func exposes(_ name: String) -> Bool { resolvedByName[name] != nil }

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
        guard let definition = resolvedByName[request.name] else {
            if Self.byName[request.name] != nil { throw ToolError.notEnabled(request.name) }
            throw ToolError.unknownTool(request.name)
        }
        let arguments = try Arguments(request, for: definition)

        return try await definition.handler(self, arguments, progress)
    }

    /// Runs a tool through authority declared by an exposed aggregate.
    /// Hidden tools remain unavailable through the public dispatch path.
    func callNested(
        _ request: ToolCall,
        reporting progress: ProgressReporter = .silent
    ) async throws -> ToolOutcome {
        guard let definition = callableByName[request.name] else {
            if Self.byName[request.name] != nil { throw ToolError.notEnabled(request.name) }
            throw ToolError.unknownTool(request.name)
        }
        let arguments = try Arguments(request, for: definition)
        return try await definition.handler(self, arguments, progress)
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

    init(structured: JSONValue, text: String) {
        self.structured = structured
        self.text = text
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
