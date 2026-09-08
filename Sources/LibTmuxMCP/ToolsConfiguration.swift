import LibTmux

extension TmuxTools {
    func showOptions(_ arguments: Arguments) async throws -> ToolOutcome {
        let scope = try await optionScope(arguments)
        let name = try arguments.string("name")
        let selected = try await server.options(scope).filter { $0.name == name }
        return .listing(
            "options",
            .array(
                selected.map {
                    .object(["name": .string($0.name), "value": .string($0.value)])
                }
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
            return .session(try await capabilitySession(target))
        case "window":
            guard let target else { throw ToolError.missingArgument("target") }
            return .window(try await capabilityWindow(target))
        case "pane":
            guard let target else { throw ToolError.missingArgument("target") }
            return .pane(try await capabilityPane(target))
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
