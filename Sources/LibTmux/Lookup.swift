/// Reading one object back, without listing the rest.
///
/// A ``Session``, ``Window`` or ``Pane`` is what the server looked like when it
/// was read, so a program that holds one and wants a newer view asks again.
///
/// These narrow the listing to the one object before it crosses the process
/// boundary, using the same lowering ``Server/panes(where:)`` uses, so what a
/// re-read costs does not grow with the size of the server. Searching a full
/// listing — `try await server.panes().first { $0.id == pane.id }` — answers
/// the same question by formatting, piping and decoding every other pane too.
///
/// ```swift
/// guard let fresh = try await server.refresh(pane) else { return }  // still there
/// let work = try await server.session(named: "work")                // by name
/// ```
///
/// Absence is `nil` rather than an error: an object going away is ordinary, and
/// a caller that wants it to be fatal can say so with `guard`. A server that
/// cannot answer at all still throws.
extension Server {
    // MARK: By id

    /// The session with this id, or `nil` if the server has no such session.
    public func session(_ id: SessionID) async throws(TmuxError) -> Session? {
        try await narrowedSessions(
            .comparison(field: "session.id", operation: .equals(.text(id.rawValue)))
        ).first
    }

    /// The window with this id, or `nil` if the server has no such window.
    public func window(_ id: WindowID) async throws(TmuxError) -> Window? {
        try await narrowedWindows(
            .comparison(field: "window.id", operation: .equals(.text(id.rawValue)))
        ).first
    }

    /// The pane with this id, or `nil` if the server has no such pane.
    public func pane(_ id: PaneID) async throws(TmuxError) -> Pane? {
        try await narrowedPanes(
            .comparison(field: "pane.id", operation: .equals(.text(id.rawValue)))
        ).first
    }

    // MARK: By name

    /// The session with this name, or `nil` if no session has it.
    ///
    /// Names are unique among sessions, which is why this returns one rather
    /// than a list. Use ``hasSession(_:)`` when only existence matters — it asks
    /// tmux a question it answers with an exit status and decodes nothing.
    public func session(named name: String) async throws(TmuxError) -> Session? {
        try await narrowedSessions(
            .comparison(field: "session.name", operation: .equals(.text(name)))
        ).first
    }

    /// Every window with this name, in tmux's own order.
    ///
    /// A plural, unlike ``session(named:)``: tmux lets two windows share a name,
    /// so returning one would be picking arbitrarily.
    public func windows(named name: String) async throws(TmuxError) -> [Window] {
        try await narrowedWindows(
            .comparison(field: "window.name", operation: .equals(.text(name)))
        )
    }

    // MARK: Re-reading a value

    /// This session as it is now, or `nil` if it has gone away.
    public func refresh(_ session: Session) async throws(TmuxError) -> Session? {
        _ = try expectedIncarnation([session.incarnation])
        return try sameDaemon(
            try await self.session(session.id),
            as: session.incarnation,
            reading: \.incarnation
        )
    }

    /// This window as it is now, or `nil` if it has gone away.
    public func refresh(_ window: Window) async throws(TmuxError) -> Window? {
        _ = try expectedIncarnation([window.incarnation])
        return try sameDaemon(
            try await self.window(window.id),
            as: window.incarnation,
            reading: \.incarnation
        )
    }

    /// This pane as it is now, or `nil` if it has gone away.
    ///
    /// What the pane reports about itself — its size, what is running in it,
    /// where it is — is what changes; its id does not.
    public func refresh(_ pane: Pane) async throws(TmuxError) -> Pane? {
        _ = try expectedIncarnation([pane.incarnation])
        return try sameDaemon(
            try await self.pane(pane.id),
            as: pane.incarnation,
            reading: \.incarnation
        )
    }

    // MARK: Plumbing

    /// Insists the row came from the daemon the held value did.
    ///
    /// Two different failures. A value from another endpoint is refused before
    /// anything is sent — that is a programming error, not a race. A value from
    /// a *replaced* daemon at the same endpoint can only be caught after the
    /// read, and it must be: tmux restarts its ids at zero, so `%1` on the new
    /// server is a different pane with the same name.
    ///
    /// The check reads the incarnation off the row that came back rather than
    /// asking the server again. A second round trip would leave the same gap it
    /// was meant to close — the restart could land between the two calls — and
    /// every projection already carries the daemon's identity.
    private func sameDaemon<Element>(
        _ found: Element?,
        as incarnation: ServerIncarnation,
        reading identity: (Element) -> ServerIncarnation
    ) throws(TmuxError) -> Element? {
        guard let found else { return nil }
        guard identity(found) == incarnation else { throw .serverRestarted }
        return found
    }

    private func narrowedSessions(
        _ expression: FilterExpr<Session>
    ) async throws(TmuxError) -> [Session] {
        do {
            return try await sessions(where: expression)
        } catch {
            throw error.asTmuxError
        }
    }

    private func narrowedWindows(
        _ expression: FilterExpr<Window>
    ) async throws(TmuxError) -> [Window] {
        do {
            return try await windows(where: expression)
        } catch {
            throw error.asTmuxError
        }
    }

    private func narrowedPanes(
        _ expression: FilterExpr<Pane>
    ) async throws(TmuxError) -> [Pane] {
        do {
            return try await panes(where: expression)
        } catch {
            throw error.asTmuxError
        }
    }

}

extension FilteredListingError {
    /// This failure as the error type the rest of the library throws.
    ///
    /// A lookup builds its own expression and never puts a regular expression
    /// in one, so ``matching(_:)`` cannot arise there — it is mapped rather
    /// than ignored so that adding a regex-carrying lookup later fails loudly
    /// in the reason string instead of silently returning nothing.
    var asTmuxError: TmuxError {
        switch self {
        case let .tmux(error): error
        case let .matching(error): .invocationFailed(reason: String(describing: error))
        }
    }
}
