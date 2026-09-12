/// Why a filtered listing failed.
///
/// Two independent things can go wrong, and collapsing them would hide which:
/// tmux can refuse the listing, and a regular expression in the filter can
/// exhaust its budget while the results are being narrowed.
///
/// Shaped like ``OutputWaitError`` for the same reason it is — a caller that
/// only cares about one of the two should not have to unwrap a string.
public enum FilteredListingError: Error, Sendable, Hashable {
    case tmux(TmuxError)
    case matching(RegexMatchError)
}

/// Listings tmux narrows before they cross the process boundary.
///
/// ``Server/panes()`` reads every pane on the server and hands them all back;
/// filtering afterwards means the rows you discard were still formatted, piped,
/// and decoded. These take the filter with them: tmux evaluates as much of it
/// as its format language can express and returns only the rows that survive.
///
/// ```swift
/// let editors = try await server.panes(
///     where: .where(\.currentCommand, .isIn(["nvim", "vim"]))
/// )
/// ```
///
/// The answer is identical to filtering at home. Lowering is deliberately
/// incomplete — a regular expression runs on this package's bounded engine
/// rather than tmux's, so it is left out of the predicate — and whatever tmux
/// could not decide is decided here, on the smaller set it returned. tmux
/// narrows; Swift still has the last word.
extension Server {
    /// Sessions matching `expression`.
    public func sessions(
        where expression: FilterExpr<Session>
    ) async throws(FilteredListingError) -> [Session] {
        try await filtered(
            expression,
            listing: { predicate in
                TmuxCommand(
                    "list-sessions",
                    ["-f", predicate, "-F", Session.projection.template]
                )
            },
            projection: Session.projection,
            row: { Session(row: $0, endpoint: self.endpoint) }
        )
    }

    /// Windows matching `expression`.
    ///
    /// A window linked into more than one session appears once, as in
    /// ``windows()``.
    public func windows(
        where expression: FilterExpr<Window>
    ) async throws(FilteredListingError) -> [Window] {
        var seen: Set<WindowID> = []
        return try await filtered(
            expression,
            listing: { predicate in
                TmuxCommand(
                    "list-windows",
                    ["-a", "-f", predicate, "-F", WindowAppearance.projection.template]
                )
            },
            projection: WindowAppearance.projection,
            row: { WindowAppearance(row: $0, endpoint: self.endpoint).window }
        ).filter { seen.insert($0.id).inserted }
    }

    /// Panes matching `expression`.
    public func panes(
        where expression: FilterExpr<Pane>
    ) async throws(FilteredListingError) -> [Pane] {
        var seen: Set<PaneID> = []
        return try await filtered(
            expression,
            listing: { predicate in
                TmuxCommand(
                    "list-panes",
                    ["-a", "-f", predicate, "-F", Pane.projection.template]
                )
            },
            projection: Pane.projection,
            row: { Pane(row: $0, endpoint: self.endpoint) }
        ).filter { seen.insert($0.id).inserted }
    }

    /// Clients matching `expression`.
    ///
    /// The one listing here that does not push its filter to tmux. `-f` reached
    /// `list-clients` in tmux 3.4, three releases after this package's floor,
    /// and asking an older server for it fails the whole listing rather than
    /// being ignored. Version-gating it would buy nothing worth the round trip:
    /// a server has one client per attachment, so there is no long list to
    /// narrow. The expression is applied here, and the answer is the same.
    public func clients(
        where expression: FilterExpr<Client>
    ) async throws(FilteredListingError) -> [Client] {
        try await filtered(
            expression,
            listing: { _ in
                TmuxCommand("list-clients", ["-F", Client.projection.template])
            },
            projection: Client.projection,
            row: { Client(row: $0, endpoint: self.endpoint) }
        )
    }

    /// Runs a listing narrowed by `expression`, then applies it exactly.
    ///
    /// The second pass is not a fallback — it is what makes the first one safe
    /// to approximate. Skipping it when the predicate happens to be exact would
    /// buy a pass over an already-short array and cost the invariant that this
    /// and the local `filter(_:)` cannot disagree.
    private func filtered<Element: Filterable>(
        _ expression: FilterExpr<Element>,
        listing: (String) -> TmuxCommand,
        projection: FormatProjection,
        row: (FormatRow) -> Element
    ) async throws(FilteredListingError) -> [Element] {
        let command = listing(expression.tmuxPredicate)
        let reply: TmuxReply
        do {
            reply = try await run(command)
        } catch {
            throw .tmux(error)
        }
        // A filter that excluded every row is still a success: tmux exits 0
        // and prints nothing, on every supported release. So a nonzero status
        // is a failure with no ambiguity to resolve — treating an empty
        // standard error as "matched nothing" would report absence for a
        // client that was killed before it could say anything.
        guard reply.isSuccess else {
            throw .tmux(reply.failure(for: command))
        }
        let rows: [FormatRow]
        do {
            rows = try projection.decode(reply.standardOutput)
        } catch {
            throw .tmux(.decodingFailed(error))
        }
        do {
            return try rows.map(row).filter(expression)
        } catch {
            throw .matching(error)
        }
    }
}
