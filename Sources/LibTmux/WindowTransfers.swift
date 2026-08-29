extension Server {
    // MARK: Moving windows between sessions

    /// Moves one window appearance into another session.
    public func move(
        _ link: WindowLink,
        to destination: Session
    ) async throws(TmuxError) -> WindowLink {
        try await transfer(link, into: destination, moving: true)
    }

    /// Links a window into another session. The same window then appears in
    /// both, sharing one id — which is tmux's model, not a copy. The source is
    /// global because no existing session-local appearance is involved.
    public func link(
        _ window: Window,
        into session: Session
    ) async throws(TmuxError) -> WindowLink {
        try await transfer(
            sourceTarget: window.id.rawValue,
            windowID: window.id,
            sourceSessionID: nil,
            sourceValue: .window(window),
            into: session,
            moving: false
        )
    }

    /// Removes one of a linked window's appearances. The window survives while
    /// any session still holds it.
    public func unlink(_ link: WindowLink) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("unlink-window", ["-t", link.target]),
            guardedBy: [.windowLink(link)]
        )
    }

    private func transfer(
        _ source: WindowLink,
        into destination: Session,
        moving: Bool
    ) async throws(TmuxError) -> WindowLink {
        try await transfer(
            sourceTarget: source.target,
            windowID: source.windowID,
            sourceSessionID: source.sessionID,
            sourceValue: .windowLink(source),
            into: destination,
            moving: moving
        )
    }

    private func transfer(
        sourceTarget: String,
        windowID: WindowID,
        sourceSessionID: SessionID?,
        sourceValue: GuardedValue,
        into destination: Session,
        moving: Bool
    ) async throws(TmuxError) -> WindowLink {
        let incarnation = try expectedIncarnation([
            sourceValue.incarnation, destination.incarnation,
        ])
        guard !moving || sourceSessionID != destination.id else {
            throw .invocationFailed(reason: "move destination is the source session")
        }
        let commandName = moving ? "move-window" : "link-window"

        for _ in 0..<64 {
            let destinationLinks = try await windowLinks().filter {
                $0.incarnation == incarnation && $0.sessionID == destination.id
            }
            let occupied = Set(destinationLinks.map(\.index))
            var index = occupied.min() ?? 0
            while occupied.contains(index) { index += 1 }

            let reply = try await runGuarded(
                TmuxCommand(
                    commandName,
                    [
                        "-d", "-s", sourceTarget, "-t",
                        "\(destination.id.rawValue):\(index)",
                    ]
                ),
                by: [sourceValue, .session(destination)]
            )
            if reply.isSuccess {
                return WindowLink(
                    sessionID: destination.id,
                    windowID: windowID,
                    index: index,
                    isActive: false,
                    incarnation: incarnation
                )
            }
            // Another client can take the index between the listing and the
            // command. tmux says so in these words, unchanged since 3.2a.
            guard
                reply.errorText == "index in use: \(index)"
                    || reply.errorText == "same index: \(index)"
            else {
                throw .invocationFailed(reason: reply.errorText)
            }
        }
        throw .invocationFailed(reason: "could not reserve a destination window index")
    }
}
