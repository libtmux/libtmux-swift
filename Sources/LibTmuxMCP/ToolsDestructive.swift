import LibTmux

extension TmuxTools {
    func killPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("pane")
        let pane = try await pane(target)
        try await guardForCaller()
            .checkPane(pane.id, override: try arguments.bool("confirm_self", or: false))
        try await server.kill(pane)
        return .init(
            Killed(
                ref: WireReferenceCodec.processLocal.reference(to: pane),
                kind: "pane",
                id: pane.id.rawValue
            )
        )
    }

    func killWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let window = try WireReferenceCodec.processLocal.resolve(
            target,
            among: try await server.windows(),
            argument: "target",
            refreshWith: "list_windows or snapshot"
        )
        try await guardForCaller()
            .checkWindow(
                window.id,
                override: try arguments.bool("confirm_self", or: false)
            )
        try await server.kill(window)
        return .init(
            Killed(
                ref: WireReferenceCodec.processLocal.reference(to: window),
                kind: "window",
                id: window.id.rawValue
            )
        )
    }

    func killSession(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let snapshot = try await server.snapshot()
        let session = try WireReferenceCodec.processLocal.resolve(
            target,
            among: snapshot.sessions,
            argument: "target",
            refreshWith: "list_sessions"
        )
        try CallerGuard(
            identity: caller,
            isSameServer: caller?.isOn(serverProcessID: snapshot.serverProcessID) ?? false
        )
        .checkSession(
            session.id,
            override: try arguments.bool("confirm_self", or: false)
        )
        try await server.kill(session)
        return .init(
            Killed(
                ref: WireReferenceCodec.processLocal.reference(to: session),
                kind: "session",
                id: session.id.rawValue
            )
        )
    }

    func respawnPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        try await guardForCaller()
            .checkPane(pane.id, override: try arguments.bool("confirm_self", or: false))
        try await server.respawn(pane, running: try arguments.strings("command"))
        return .init(
            Respawned(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue
            )
        )
    }

    func killServer(_ arguments: Arguments) async throws -> ToolOutcome {
        let incarnation = try await serverIncarnation(try arguments.string("server_ref"))
        let reference = WireReferenceCodec.processLocal.reference(to: incarnation)
        try await guardForCaller()
            .checkServer(override: try arguments.bool("confirm_self", or: false))
        try await server.killServer(expecting: incarnation)
        return .init(Killed(ref: reference, kind: "server", id: String(incarnation.processID)))
    }
}
