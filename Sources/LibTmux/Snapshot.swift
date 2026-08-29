/// Every object read from one daemon incarnation.
///
/// A snapshot spans several tmux commands. It rejects a daemon replacement
/// during capture, but another client can still mutate one daemon between its
/// listings; this is a bounded aggregate, not a tmux transaction.
public struct Snapshot: Sendable, Hashable, Codable {
    /// The daemon the whole capture came from.
    public let incarnation: ServerIncarnation
    public var serverProcessID: Int { incarnation.processID }
    /// Every session that existed when the capture ran, in tmux's own order.
    /// These are values: walking them cannot reach tmux again, so a relation
    /// resolved here is resolved for good.
    public let sessions: [Session]
    /// Every underlying window, on the same terms as ``sessions``.
    public let windows: [Window]
    /// Every session-local appearance of those windows.
    public let windowLinks: [WindowLink]
    /// Every pane, on the same terms as ``sessions``.
    public let panes: [Pane]
    /// Every attached client, on the same terms as ``sessions``.
    public let clients: [Client]

    public init(
        incarnation: ServerIncarnation,
        sessions: [Session],
        windows: [Window],
        windowLinks: [WindowLink],
        panes: [Pane],
        clients: [Client]
    ) {
        self.incarnation = incarnation
        self.sessions = sessions
        self.windows = windows
        self.windowLinks = windowLinks
        self.panes = panes
        self.clients = clients
    }
}

// MARK: - Relations

extension Snapshot {
    /// The windows of a session, in tmux's order.
    public func windows(of session: Session) -> [Window] {
        guard session.incarnation == incarnation else { return [] }
        let byID = Dictionary(
            fromIncarnation(windows).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<WindowID> = []
        return windowLinks(of: session).compactMap { link in
            guard let window = byID[link.windowID], seen.insert(link.windowID).inserted else {
                return nil
            }
            return window
        }
    }

    /// The session-local window links of a session, in tmux's order.
    public func windowLinks(of session: Session) -> [WindowLink] {
        guard session.incarnation == incarnation else { return [] }
        return fromIncarnation(windowLinks).filter { $0.sessionID == session.id }
    }

    /// Every link to a window, including repeated links in one session.
    public func links(of window: Window) -> [WindowLink] {
        guard window.incarnation == incarnation else { return [] }
        return fromIncarnation(windowLinks).filter { $0.windowID == window.id }
    }

    /// The panes of a window, in tmux's order.
    public func panes(of window: Window) -> [Pane] {
        guard window.incarnation == incarnation else { return [] }
        return fromIncarnation(panes).filter { $0.windowID == window.id }
    }

    /// Every pane in a session, across all its windows.
    public func panes(of session: Session) -> [Pane] {
        guard session.incarnation == incarnation else { return [] }
        let byWindow = Dictionary(grouping: fromIncarnation(panes), by: \.windowID)
        var seen: Set<PaneID> = []
        return windowLinks(of: session)
            .flatMap { byWindow[$0.windowID] ?? [] }
            .filter { seen.insert($0.id).inserted }
    }

    /// Every session linking a window, in tmux's order.
    public func sessions(of window: Window) -> [Session] {
        guard window.incarnation == incarnation else { return [] }
        let ids = Set(links(of: window).map(\.sessionID))
        return fromIncarnation(sessions).filter { ids.contains($0.id) }
    }

    /// The session a client is attached to, if the snapshot still holds it.
    public func session(of client: Client) -> Session? {
        guard client.incarnation == incarnation else { return nil }
        return fromIncarnation(sessions).first { $0.id == client.sessionID }
    }

    /// The clients attached to a session.
    public func clients(of session: Session) -> [Client] {
        guard session.incarnation == incarnation else { return [] }
        return fromIncarnation(clients).filter { $0.sessionID == session.id }
    }

    private func fromIncarnation<Value: SnapshotMember>(_ values: [Value]) -> [Value] {
        values.filter { $0.incarnation == incarnation }
    }
}

private protocol SnapshotMember {
    var incarnation: ServerIncarnation { get }
}

extension Session: SnapshotMember {}
extension Window: SnapshotMember {}
extension WindowLink: SnapshotMember {}
extension Pane: SnapshotMember {}
extension Client: SnapshotMember {}

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
    ) throws(RegexMatchError) -> [Session] {
        try sessions(
            quantifier,
            ofPanes: expression,
            regexBudget: RegexMatchBudget()
        )
    }

    package func sessions(
        _ quantifier: RelationQuantifier,
        ofPanes expression: FilterExpr<Pane>,
        regexBudget: RegexMatchBudget
    ) throws(RegexMatchError) -> [Session] {
        var result: [Session] = []
        for session in fromIncarnation(sessions) {
            let related = panes(of: session)
            let matches = try related.count { (pane: Pane) throws(RegexMatchError) in
                try expression.matches(pane, budget: regexBudget)
            }
            if quantifier.holds(over: matches, of: related.count) {
                result.append(session)
            }
        }
        return result
    }

    /// Sessions whose windows satisfy a quantified filter.
    public func sessions(
        _ quantifier: RelationQuantifier,
        ofWindows expression: FilterExpr<Window>
    ) throws(RegexMatchError) -> [Session] {
        try sessions(
            quantifier,
            ofWindows: expression,
            regexBudget: RegexMatchBudget()
        )
    }

    package func sessions(
        _ quantifier: RelationQuantifier,
        ofWindows expression: FilterExpr<Window>,
        regexBudget: RegexMatchBudget
    ) throws(RegexMatchError) -> [Session] {
        var result: [Session] = []
        for session in fromIncarnation(sessions) {
            let related = windows(of: session)
            let matches = try related.count { (window: Window) throws(RegexMatchError) in
                try expression.matches(window, budget: regexBudget)
            }
            if quantifier.holds(over: matches, of: related.count) {
                result.append(session)
            }
        }
        return result
    }

    /// Windows whose panes satisfy a quantified filter.
    public func windows(
        _ quantifier: RelationQuantifier,
        ofPanes expression: FilterExpr<Pane>
    ) throws(RegexMatchError) -> [Window] {
        try windows(
            quantifier,
            ofPanes: expression,
            regexBudget: RegexMatchBudget()
        )
    }

    package func windows(
        _ quantifier: RelationQuantifier,
        ofPanes expression: FilterExpr<Pane>,
        regexBudget: RegexMatchBudget
    ) throws(RegexMatchError) -> [Window] {
        var result: [Window] = []
        for window in fromIncarnation(windows) {
            let related = panes(of: window)
            let matches = try related.count { (pane: Pane) throws(RegexMatchError) in
                try expression.matches(pane, budget: regexBudget)
            }
            if quantifier.holds(over: matches, of: related.count) {
                result.append(window)
            }
        }
        return result
    }

    /// Panes whose window matches — the to-one direction, where a quantifier
    /// would say nothing.
    public func panes(
        inWindow expression: FilterExpr<Window>
    ) throws(RegexMatchError) -> [Pane] {
        let matching = Set(try fromIncarnation(windows).filter(expression).map(\.id))
        return fromIncarnation(panes).filter { matching.contains($0.windowID) }
    }

    /// Panes whose session matches.
    public func panes(
        inSession expression: FilterExpr<Session>
    ) throws(RegexMatchError) -> [Pane] {
        let matching = Set(try fromIncarnation(sessions).filter(expression).map(\.id))
        let windowIDs = Set(
            fromIncarnation(windowLinks).lazy.filter { matching.contains($0.sessionID) }.map(
                \.windowID
            )
        )
        return fromIncarnation(panes).filter { windowIDs.contains($0.windowID) }
    }

    /// Windows whose session matches.
    public func windows(
        inSession expression: FilterExpr<Session>
    ) throws(RegexMatchError) -> [Window] {
        let matching = Set(try fromIncarnation(sessions).filter(expression).map(\.id))
        let linked = Set(
            fromIncarnation(windowLinks).lazy.filter { matching.contains($0.sessionID) }.map(
                \.windowID
            )
        )
        return fromIncarnation(windows).filter { linked.contains($0.id) }
    }
}

extension Sequence {
    fileprivate func count(
        where predicate: (Element) throws(RegexMatchError) -> Bool
    ) throws(RegexMatchError) -> Int {
        var result = 0
        for element in self where try predicate(element) { result += 1 }
        return result
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
    public func sessions(
        ofPanes query: RelationQuery<Pane>
    ) throws(RegexMatchError) -> [Session] {
        try sessions(query.quantifier, ofPanes: query.expression)
    }

    /// Sessions whose windows satisfy a quantified filter.
    public func sessions(
        ofWindows query: RelationQuery<Window>
    ) throws(RegexMatchError) -> [Session] {
        try sessions(query.quantifier, ofWindows: query.expression)
    }

    /// Windows whose panes satisfy a quantified filter.
    public func windows(
        ofPanes query: RelationQuery<Pane>
    ) throws(RegexMatchError) -> [Window] {
        try windows(query.quantifier, ofPanes: query.expression)
    }
}
