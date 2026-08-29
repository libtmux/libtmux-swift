import LibTmux

extension TmuxTools {
    func setOption(_ arguments: Arguments) async throws -> ToolOutcome {
        guard let incarnation = try await server.incarnation() else {
            throw ToolError.refusedForSafety("the tmux server is not running")
        }
        let name = try arguments.string("name")
        let value = try arguments.string("value")
        let scope = try arguments.string("scope", or: "server")
        var flags: [String] = []
        switch scope {
        case "server": flags = ["-s"]
        case "global": flags = ["-g"]
        default: flags = []
        }
        let reply = try await server.runIsolated(
            TmuxCommand("set-option", flags + [name, value]),
            expecting: incarnation,
            perStreamOutputLimit: 65_536
        )
        return .init(
            CommandResult(
                serverRef: WireReferenceCodec.processLocal.reference(to: incarnation),
                exitCode: reply.exitCode,
                standardOutput: reply.text,
                standardError: reply.errorText
            )
        )
    }

    func setEnvironment(_ arguments: Arguments) async throws -> ToolOutcome {
        guard let incarnation = try await server.incarnation() else {
            throw ToolError.refusedForSafety("the tmux server is not running")
        }
        let name = try arguments.string("name")
        let value = try arguments.optionalString("value")
        let command = TmuxCommand(
            "set-environment",
            value.map { ["-g", name, $0] } ?? ["-g", "-u", name]
        )
        let reply = try await server.runIsolated(
            command,
            expecting: incarnation,
            perStreamOutputLimit: 65_536
        )
        guard reply.isSuccess else { throw ToolError.tmuxRejected(reply.errorText) }
        return .init(
            EnvironmentSet(
                serverRef: WireReferenceCodec.processLocal.reference(to: incarnation),
                name: name,
                value: value
            )
        )
    }
}
