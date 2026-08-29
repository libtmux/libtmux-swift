import LibTmux

extension TmuxTools {
    func showOptions(_ arguments: Arguments) async throws -> ToolOutcome {
        let scope = try await optionScope(arguments)
        let listed = try await server.options(scope)
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

    func setOption(_ arguments: Arguments) async throws -> ToolOutcome {
        let incarnation = try await server.incarnation()
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
        let incarnation = try await server.incarnation()
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

    private func optionScope(_ arguments: Arguments) async throws -> OptionScope {
        let scope = try arguments.string("scope", or: "server")
        let target = try arguments.optionalString("target")
        switch scope {
        case "server":
            try rejectOptionTarget(target, for: scope)
            return .server
        case "global_session":
            try rejectOptionTarget(target, for: scope)
            return .globalSession
        case "global_window":
            try rejectOptionTarget(target, for: scope)
            return .globalWindow
        case "session":
            guard let target else { throw ToolError.missingArgument("target") }
            return .session(
                try WireReferenceCodec.processLocal.resolve(
                    target,
                    among: try await server.sessions(),
                    argument: "target",
                    refreshWith: "list_sessions"
                )
            )
        case "window":
            guard let target else { throw ToolError.missingArgument("target") }
            return .window(
                try WireReferenceCodec.processLocal.resolve(
                    target,
                    among: try await server.windows(),
                    argument: "target",
                    refreshWith: "list_windows"
                )
            )
        case "pane":
            guard let target else { throw ToolError.missingArgument("target") }
            return .pane(
                try WireReferenceCodec.processLocal.resolve(
                    target,
                    among: try await server.panes(),
                    argument: "target",
                    refreshWith: "list_panes"
                )
            )
        default:
            preconditionFailure("the argument reader rejects undeclared scopes")
        }
    }

    private func rejectOptionTarget(_ target: String?, for scope: String) throws {
        guard target == nil else {
            throw ToolError.wrongArgumentType(
                "target",
                expected: "omitted when scope is \(scope)"
            )
        }
    }
}
