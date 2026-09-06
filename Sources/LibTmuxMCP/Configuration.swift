import Foundation
import LibTmux

public struct ServerProvenance: Sendable, Hashable, Codable {
    public let selector: String
    public let selectionProvenance: String
    public let serverState: String
    public let configurationProvenance: String
    public let resolvedSocketPath: String?
    public let attachCommand: String?

    public init(
        selector: String,
        selectionProvenance: String,
        serverState: String,
        configurationProvenance: String,
        resolvedSocketPath: String? = nil,
        attachCommand: String? = nil
    ) {
        self.selector = selector
        self.selectionProvenance = selectionProvenance
        self.serverState = serverState
        self.configurationProvenance = configurationProvenance
        self.resolvedSocketPath = resolvedSocketPath
        self.attachCommand = attachCommand
    }

    public static let unknown = ServerProvenance(
        selector: "unknown",
        selectionProvenance: "operator-current",
        serverState: "unprobed",
        configurationProvenance: "unknown",
        resolvedSocketPath: nil,
        attachCommand: nil
    )
}

package struct StartupPin: Sendable {
    package let server: Server
    package let authority: ToolAuthority
    package let provenance: ServerProvenance
    package let ownsLaunch: Bool
}

/// How the executable is configured, read from the environment.
///
/// An MCP server is launched by a client that passes no flags, so environment
/// is the only configuration surface there is. Parsed here rather than in the
/// executable so a test can check what a given environment produces.
public struct ServerConfiguration: Sendable, Hashable {
    public let socketName: String?
    public let socketPath: String?
    public let tmuxExecutable: String
    public let tmuxConfigurationFile: String?
    public let isDefaultDedicatedMinimal: Bool
    public let authority: ToolAuthority
    public let waitCeiling: Duration
    /// Anything the environment asked for that could not be honoured, to be
    /// reported on standard error rather than silently applied differently.
    public let warnings: [String]
    /// Fatal configuration errors. The executable reports these before it
    /// constructs or probes a tmux server.
    public let errors: [String]

    /// A wait longer than this is refused however it is configured. A client
    /// that hangs for minutes on one call is indistinguishable from one that
    /// has died.
    public static let hardWaitCeiling: Double = 300

    public init(environment: [String: String]) {
        var warnings: [String] = []
        var errors: [String] = []

        let configuredName = environment["LIBTMUX_SOCKET"]
        let configuredPath = environment["LIBTMUX_SOCKET_PATH"]
        let configuredConfiguration = environment["LIBTMUX_TMUX_CONFIG"]
        if configuredPath != nil, configuredName != nil {
            errors.append("set only one of LIBTMUX_SOCKET_PATH and LIBTMUX_SOCKET")
        }
        if configuredName?.isEmpty == true { errors.append("LIBTMUX_SOCKET must not be empty") }
        if let configuredPath, !configuredPath.hasPrefix("/") {
            errors.append("LIBTMUX_SOCKET_PATH must be an absolute path")
        }
        if configuredPath?.isEmpty == true {
            errors.append("LIBTMUX_SOCKET_PATH must not be empty")
        }
        if let configuredConfiguration, !configuredConfiguration.hasPrefix("/") {
            errors.append("LIBTMUX_TMUX_CONFIG must be a nonempty absolute path")
        }
        self.isDefaultDedicatedMinimal =
            configuredPath == nil && configuredName == nil && configuredConfiguration == nil
        self.socketPath = configuredPath
        self.socketName = configuredPath == nil ? (configuredName ?? "libtmux-mcp") : nil
        self.tmuxExecutable = environment["LIBTMUX_TMUX_BIN"] ?? "tmux"
        self.tmuxConfigurationFile =
            configuredConfiguration
            ?? (isDefaultDedicatedMinimal ? Self.bundledMinimalConfiguration : nil)

        if environment.keys.contains("LIBTMUX_TMUX_CONF") {
            errors.append("LIBTMUX_TMUX_CONF is retired; use LIBTMUX_TMUX_CONFIG")
        }

        if environment.keys.contains("LIBTMUX_SAFETY") {
            errors.append(
                "LIBTMUX_SAFETY is retired; use LIBTMUX_TOOLSETS, LIBTMUX_TOOLS, "
                    + "and LIBTMUX_EXCLUDE_TOOLS"
            )
        }
        if environment.keys.contains("LIBTMUX_MCP_TOOLS") {
            errors.append(
                "LIBTMUX_MCP_TOOLS is retired; use LIBTMUX_TOOLSETS= with LIBTMUX_TOOLS"
            )
        }

        let knownTools = Set(TmuxTools.definitions.map(\.name))
        let explicitToolsets = environment.keys.contains("LIBTMUX_TOOLSETS")
        let parsedToolsets = Self.parseList(
            environment["LIBTMUX_TOOLSETS"],
            variable: "LIBTMUX_TOOLSETS",
            allowWholeEmpty: true,
            errors: &errors
        )
        var toolsets: Set<Toolset> =
            explicitToolsets
            ? [] : [.inspect, .manage, .execute]
        for name in parsedToolsets {
            guard let toolset = Toolset(rawValue: name) else {
                errors.append("unknown LIBTMUX_TOOLSETS name: \(name)")
                continue
            }
            toolsets.insert(toolset)
        }

        let included = Set(
            Self.parseList(
                environment["LIBTMUX_TOOLS"],
                variable: "LIBTMUX_TOOLS",
                allowWholeEmpty: true,
                errors: &errors
            ))
        let excluded = Set(
            Self.parseList(
                environment["LIBTMUX_EXCLUDE_TOOLS"],
                variable: "LIBTMUX_EXCLUDE_TOOLS",
                allowWholeEmpty: true,
                errors: &errors
            ))
        for name in included.union(excluded).subtracting(knownTools).sorted() {
            errors.append("unknown tool name: \(name)")
        }
        self.authority = ToolAuthority(
            toolsets: errors.isEmpty ? toolsets : [],
            includedTools: errors.isEmpty ? included : [],
            excludedTools: errors.isEmpty ? excluded : [],
            usedExplicitToolsets: explicitToolsets
        )

        let rawCeiling = environment["LIBTMUX_MCP_WAIT_MAX_SECONDS"]
        var requestedCeiling: Double?
        if let rawCeiling {
            if let parsed = Double(rawCeiling), parsed.isFinite {
                requestedCeiling = parsed
            } else {
                warnings.append(
                    "LIBTMUX_MCP_WAIT_MAX_SECONDS=\(rawCeiling) is not a finite number; "
                        + "using 120s"
                )
            }
        }
        if let requestedCeiling, requestedCeiling > Self.hardWaitCeiling {
            warnings.append(
                "LIBTMUX_MCP_WAIT_MAX_SECONDS=\(rawCeiling ?? String(requestedCeiling)) "
                    + "exceeds the "
                    + "\(Int(Self.hardWaitCeiling))s hard ceiling; using that instead"
            )
        }
        if let requestedCeiling, requestedCeiling < 1 {
            warnings.append(
                "LIBTMUX_MCP_WAIT_MAX_SECONDS=\(rawCeiling ?? String(requestedCeiling)) "
                    + "is below the 1s floor; using that instead"
            )
        }
        let ceiling = min(requestedCeiling ?? 120, Self.hardWaitCeiling)
        self.waitCeiling = .seconds(max(1, ceiling))
        self.warnings = warnings
        self.errors = errors
    }

    private static var bundledMinimalConfiguration: String? {
        Bundle.module.url(forResource: "minimal", withExtension: "conf")?.path
    }

    private static func parseList(
        _ value: String?,
        variable: String,
        allowWholeEmpty: Bool,
        errors: inout [String]
    ) -> [String] {
        guard let value else { return [] }
        if value.isEmpty, allowWholeEmpty { return [] }
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard tokens.allSatisfy({ !$0.isEmpty }) else {
            errors.append("\(variable) contains an empty token")
            return []
        }
        return tokens
    }

    private func authorityForStartup(ownsLaunch: Bool) -> ToolAuthority {
        guard !authority.usedExplicitToolsets, isDefaultDedicatedMinimal, ownsLaunch else {
            return authority
        }
        return ToolAuthority(
            toolsets: authority.toolsets.union([.teardown]),
            includedTools: authority.includedTools,
            excludedTools: authority.excludedTools,
            usedExplicitToolsets: false
        )
    }

    private func externalProvenance(
        wasRunning: Bool,
        resolvedSocketPath: String?
    ) -> ServerProvenance {
        return ServerProvenance(
            selector: socketPath.map { "path:\($0)" }
                ?? "name:\(socketName ?? "default")",
            selectionProvenance: "operator-current",
            serverState: wasRunning ? "existing" : "absent",
            configurationProvenance: wasRunning ? "unknown" : "user-configured",
            resolvedSocketPath: resolvedSocketPath,
            attachCommand: attachCommand()
        )
    }

    package func pinForStartup(
        server suppliedServer: Server? = nil,
        ownerNonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased()
    ) async throws(TmuxError) -> StartupPin {
        let server: Server
        if let suppliedServer {
            server = suppliedServer
        } else {
            server = try makeServer()
        }

        guard isDefaultDedicatedMinimal else {
            let wasRunning = try await server.isRunning()
            let resolvedSocketPath =
                if wasRunning {
                    try await server.incarnation().socketPath
                } else {
                    socketPath
                }
            return StartupPin(
                server: server,
                authority: authority,
                provenance: externalProvenance(
                    wasRunning: wasRunning,
                    resolvedSocketPath: resolvedSocketPath
                ),
                ownsLaunch: false
            )
        }

        try await server.startServer(
            launchEnvironment: ["LIBTMUX_MCP_OWNER": ownerNonce]
        )
        let ownsLaunch =
            try await server.option("@libtmux_mcp_owner", scope: .globalSession) == ownerNonce
        let resolvedSocketPath = try await server.incarnation().socketPath
        let pinnedProvenance = ServerProvenance(
            selector: "name:\(socketName ?? "default")",
            selectionProvenance: "default-dedicated",
            serverState: ownsLaunch ? "created" : "existing",
            configurationProvenance: ownsLaunch ? "minimal" : "unknown",
            resolvedSocketPath: resolvedSocketPath,
            attachCommand: attachCommand()
        )
        return StartupPin(
            server: server,
            authority: authorityForStartup(ownsLaunch: ownsLaunch),
            provenance: pinnedProvenance,
            ownsLaunch: ownsLaunch
        )
    }

    public func makeServer() throws(TmuxError) -> Server {
        if let socketPath {
            let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw .invocationFailed(reason: "cannot create socket directory: \(error)")
            }
            return try Server(
                socketPath: socketPath,
                tmuxExecutable: tmuxExecutable,
                configurationFile: tmuxConfigurationFile
            )
        }
        return try Server(
            socketName: socketName ?? "default",
            tmuxExecutable: tmuxExecutable,
            configurationFile: tmuxConfigurationFile
        )
    }

    public var endpointSummary: String {
        socketPath.map { "socket path \($0)" }
            ?? "socket name \(socketName ?? "default")"
    }

    private func attachCommand() -> String {
        let endpoint =
            socketPath.map { "-S \(Self.shellQuote($0))" }
            ?? "-L \(Self.shellQuote(socketName ?? "default"))"
        return "\(Self.shellQuote(tmuxExecutable)) -N \(endpoint) attach"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
