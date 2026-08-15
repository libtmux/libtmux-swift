/// Every object on one server, read as one consistent picture.
///
/// A snapshot is taken across several tmux commands, so it carries the server
/// incarnation it was read from. If the daemon died and a new one bound the
/// same socket midway, the two reads describe different servers, and
/// ``Server/snapshot()`` reports that rather than handing back a picture that
/// never existed.
public struct Snapshot: Sendable, Hashable, Codable {
    /// The server process the whole capture came from. A restart changes it,
    /// which is what makes the capture verifiable.
    public let serverProcessID: Int
    /// Every session that existed when the capture ran, in tmux's own order.
    /// These are values: walking them cannot reach tmux again, so a relation
    /// resolved here is resolved for good.
    public let sessions: [Session]
    /// Every window, on the same terms as ``sessions``. A window linked into
    /// more than one session appears once per session.
    public let windows: [Window]
    /// Every pane, on the same terms as ``sessions``.
    public let panes: [Pane]
    /// Every attached client, on the same terms as ``sessions``.
    public let clients: [Client]

    public init(
        serverProcessID: Int,
        sessions: [Session],
        windows: [Window],
        panes: [Pane],
        clients: [Client]
    ) {
        self.serverProcessID = serverProcessID
        self.sessions = sessions
        self.windows = windows
        self.panes = panes
        self.clients = clients
    }
}

// MARK: - Relations

extension Snapshot {
    /// The windows of a session, in tmux's order.
    public func windows(of session: Session) -> [Window] {
        windows.filter { $0.sessionID == session.id }
    }

    /// The panes of a window, in tmux's order.
    public func panes(of window: Window) -> [Pane] {
        panes.filter { $0.windowID == window.id }
    }

    /// Every pane in a session, across all its windows.
    public func panes(of session: Session) -> [Pane] {
        panes.filter { $0.sessionID == session.id }
    }

    /// The session a window belongs to, if the snapshot still holds it.
    public func session(of window: Window) -> Session? {
        sessions.first { $0.id == window.sessionID }
    }

    /// The session a client is attached to, if the snapshot still holds it.
    public func session(of client: Client) -> Session? {
        sessions.first { $0.id == client.sessionID }
    }

    /// The clients attached to a session.
    public func clients(of session: Session) -> [Client] {
        clients.filter { $0.sessionID == session.id }
    }
}

/// How many related objects have to match.
public enum RelationQuantifier: String, Sendable, Hashable, Codable {
    /// At least one related object matches. An object with no relations never
    /// satisfies this.
    case some
    /// Every related object matches — vacuously true when there are none, the
    /// same way `allSatisfy` reads on an empty collection.
    case every
    /// No related object matches. An object with no relations satisfies this.
    case none

    func holds(over matchCount: Int, of total: Int) -> Bool {
        switch self {
        case .some: matchCount > 0
        case .every: matchCount == total
        case .none: matchCount == 0
        }
    }
}

// MARK: - Relation filtering

extension Snapshot {
    /// Sessions whose panes satisfy a quantified filter.
    public func sessions(
        _ quantifier: RelationQuantifier,
        ofPanes expression: FilterExpr<Pane>
    ) -> [Session] {
        sessions.filter { session in
            let related = panes(of: session)
            return quantifier.holds(
                over: related.count(where: expression.matches),
                of: related.count
            )
        }
    }

    /// Sessions whose windows satisfy a quantified filter.
    public func sessions(
        _ quantifier: RelationQuantifier,
        ofWindows expression: FilterExpr<Window>
    ) -> [Session] {
        sessions.filter { session in
            let related = windows(of: session)
            return quantifier.holds(
                over: related.count(where: expression.matches),
                of: related.count
            )
        }
    }

    /// Windows whose panes satisfy a quantified filter.
    public func windows(
        _ quantifier: RelationQuantifier,
        ofPanes expression: FilterExpr<Pane>
    ) -> [Window] {
        windows.filter { window in
            let related = panes(of: window)
            return quantifier.holds(
                over: related.count(where: expression.matches),
                of: related.count
            )
        }
    }

    /// Panes whose window matches — the to-one direction, where a quantifier
    /// would say nothing.
    public func panes(inWindow expression: FilterExpr<Window>) -> [Pane] {
        let matching = Set(windows.filter(expression).map(\.id))
        return panes.filter { matching.contains($0.windowID) }
    }

    /// Panes whose session matches.
    public func panes(inSession expression: FilterExpr<Session>) -> [Pane] {
        let matching = Set(sessions.filter(expression).map(\.id))
        return panes.filter { matching.contains($0.sessionID) }
    }

    /// Windows whose session matches.
    public func windows(inSession expression: FilterExpr<Session>) -> [Window] {
        let matching = Set(sessions.filter(expression).map(\.id))
        return windows.filter { matching.contains($0.sessionID) }
    }
}

extension Sequence {
    fileprivate func count(where predicate: (Element) -> Bool) -> Int {
        reduce(0) { predicate($1) ? $0 + 1 : $0 }
    }
}

/// A quantified filter over a relation, as one value.
///
/// Pairing the quantifier with the expression is what lets a relation filter
/// travel: "sessions where *some* pane runs nvim" is a single `Codable` thing a
/// client can send, rather than two arguments a boundary has to reassemble.
public struct RelationQuery<Related: Filterable>: Sendable, Hashable, Codable {
    /// How many of the related objects have to match for the owner to be
    /// selected.
    public let quantifier: RelationQuantifier
    /// What each related object is tested against.
    public let expression: FilterExpr<Related>

    public init(_ quantifier: RelationQuantifier, _ expression: FilterExpr<Related>) {
        self.quantifier = quantifier
        self.expression = expression
    }
}

extension Snapshot {
    /// Sessions whose panes satisfy a quantified filter.
    public func sessions(ofPanes query: RelationQuery<Pane>) -> [Session] {
        sessions(query.quantifier, ofPanes: query.expression)
    }

    /// Sessions whose windows satisfy a quantified filter.
    public func sessions(ofWindows query: RelationQuery<Window>) -> [Session] {
        sessions(query.quantifier, ofWindows: query.expression)
    }

    /// Windows whose panes satisfy a quantified filter.
    public func windows(ofPanes query: RelationQuery<Pane>) -> [Window] {
        windows(query.quantifier, ofPanes: query.expression)
    }
}
