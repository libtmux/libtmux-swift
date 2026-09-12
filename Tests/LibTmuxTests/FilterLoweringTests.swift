import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

/// A filter answered by tmux and the same filter answered here must agree.
///
/// The lowering is only allowed to be an over-approximation, so agreement is
/// the whole contract — a predicate that drops a real match is a silent wrong
/// answer rather than a failure, which is why these compare the two paths
/// against each other instead of against a hand-written expectation.
/// Stops tmux renaming a window while a case is reading its name.
///
/// `automatic-rename` follows the command running in a pane, and it overrides a
/// name given at creation — so a window called `glob*star` becomes `sh` shortly
/// after its shell starts. A case that reads every name once and then compares
/// two listings against that list races it, and reports a disagreement between
/// tmux and this package that neither had.
///
/// It is a *window* option. Setting it in the server table is refused, and
/// `setOption` reports that in a reply rather than by throwing, so the result is
/// checked here — an earlier version of this helper set the wrong table, the
/// reply went unread, and the cases stayed flaky with the fix apparently in.
func pinWindowNames(_ server: Server) async throws {
    let reply = try await server.setOption(
        "automatic-rename",
        to: "off",
        scope: .globalWindow
    )
    #expect(reply.isSuccess, "could not pin window names: \(reply.errorText)")
}

@Suite("filter lowering", .timeLimit(.minutes(2)))
struct FilterLoweringTests {
    /// Names chosen to break a naive compiler: tmux ends a format at an
    /// unescaped `}` and splits a comparison on unescaped commas, and `m`
    /// reads the pattern as glob(7).
    static let hostileNames = [
        "plain",
        "with,comma",
        "with}brace",
        "with#hash",
        "looks#{like,a}format",
        "glob*star",
        "glob?mark",
        "glob[bracket]",
        "back\\slash",
        "ünïcode",
        "  spaced  ",
    ]

    @Test("tmux-side and client-side filtering agree on hostile names")
    func loweringAgreesWithLocalFiltering() async throws {
        try await withTmuxServer { server in
            try await pinWindowNames(server)
            let session = try await server.newSession(named: "differential")
            for name in Self.hostileNames {
                _ = try await server.newWindow(in: session, named: name)
            }

            // tmux mangles some names on the way in — it expands `#{...}` in a
            // window name — so the expectations come from what it stored, never
            // from what was asked for.
            let stored = try await server.windows().map(\.name)
            #expect(stored.count > Self.hostileNames.count - 1)

            for name in stored {
                for expression in Self.expressions(for: name) {
                    let local = try await server.windows().filter(expression)
                    let lowered = try await server.windows(where: expression)
                    #expect(
                        lowered.map(\.id) == local.map(\.id),
                        """
                        disagreement on \(name.debugDescription)
                        predicate: \(expression.tmuxPredicate)
                        tmux: \(lowered.map(\.name))
                        local: \(local.map(\.name))
                        """
                    )
                }
            }
        }
    }

    static func expressions(for name: String) -> [FilterExpr<Window>] {
        var built: [FilterExpr<Window>] = []
        // A one-character slice exercises the glob operators against a value
        // that may itself contain glob syntax.
        let fragment = name.count > 2 ? String(name.dropFirst().dropLast()) : name
        for operation: FilterOperator<String> in [
            .equals(name), .caseInsensitiveEquals(name.uppercased()),
            .contains(fragment), .caseInsensitiveContains(fragment.uppercased()),
            .hasPrefix(String(name.prefix(2))), .hasSuffix(String(name.suffix(2))),
            .isIn([name, "absent"]),
        ] {
            if let expression = try? FilterExpr<Window>.where(\.name, operation) {
                built.append(expression)
                built.append(.not(expression))
                built.append(.and([expression, .not(expression)]))
                built.append(.or([expression, .not(expression)]))
            }
        }
        return built
    }

    @Test("tmux-side and client-side agree on panes, across every field type")
    func loweringAgreesOnPanes() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "panes")
            let window = try await server.newWindow(in: session, named: "split").window
            _ = try await server.splitWindow(window)
            _ = try await server.splitWindow(window, direction: .right)

            var expressions: [FilterExpr<Pane>] = try [
                // Flags. tmux answers some of these with a count, so a
                // predicate spelled `== 1` would drop rows the client keeps.
                .where(\.isActive, .equals(true)),
                .where(\.isActive, .equals(false)),
                .where(\.isDead, .equals(false)),
                .where(\.isSynchronized, .equals(false)),
                // Integers.
                .where(\.index, .equals(0)),
                .where(\.index, .isIn([0, 1])),
                // Typed identifiers.
                .where(\.windowID, .equals(window.id)),
            ]
            let commands = try await server.panes().map(\.currentCommand)
            for command in Set(commands) {
                expressions.append(try .where(\.currentCommand, .equals(command)))
                expressions.append(try .where(\.currentCommand, .contains(command)))
            }
            expressions += expressions.map { FilterExpr.not($0) }

            for expression in expressions {
                let local = try await server.panes().filter(expression)
                let lowered = try await server.panes(where: expression)
                #expect(
                    lowered.map(\.id) == local.map(\.id),
                    """
                    predicate: \(expression.tmuxPredicate)
                    tmux: \(lowered.map(\.id))
                    local: \(local.map(\.id))
                    """
                )
            }
        }
    }

    @Test("an attached session is found however many clients are attached")
    func attachmentIsNotZeroRatherThanOne() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "attached")
            let attached = try FilterExpr<Session>.where(\.isAttached, .equals(true))
            let detached = try FilterExpr<Session>.where(\.isAttached, .equals(false))

            // `session_attached` is a count of clients, so the predicate has to
            // ask "not zero". Spelled `== 1` this passes with one client and
            // silently loses the session once a second one attaches.
            #expect(attached.tmuxPredicate == "#{!=:#{session_attached},0}")
            #expect(detached.tmuxPredicate == "#{==:#{session_attached},0}")

            for expression in [attached, detached] {
                let local = try await server.sessions().filter(expression)
                let lowered = try await server.sessions(where: expression)
                #expect(lowered.map(\.id) == local.map(\.id))
            }
            _ = session
        }
    }

    @Test("filtering clients works on a server too old for list-clients -f")
    func clientsFilterWithoutPushingDown() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "clients")
            let expression = try FilterExpr<Client>.where(\.isControlMode, .equals(false))
            // tmux grew `list-clients -f` in 3.4, and this package supports
            // 3.2a — where sending it fails the listing outright rather than
            // being ignored. So this one filters at home whatever the server is.
            let local = try await server.clients().filter(expression)
            let lowered = try await server.clients(where: expression)
            #expect(lowered.map(\.name) == local.map(\.name))
        }
    }

    @Test("a case-insensitive match with non-ASCII text is decided at home")
    func nonASCIICaseFoldingStaysLocal() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "folding")
            _ = try await server.newWindow(in: session, named: "ÜBER")

            // fnmatch folds case by the server's locale; this package folds by
            // Unicode. They agree on ASCII and need not beyond it.
            let wide = try FilterExpr<Window>.where(\.name, .caseInsensitiveEquals("über"))
            #expect(wide.tmuxPredicate == "1")
            #expect(!wide.isFullyLowered)

            // An ASCII literal still reaches tmux — it just may not be negated,
            // because `m/i` folds by the server's locale and globs over bytes.
            let ascii = try FilterExpr<Window>.where(\.name, .caseInsensitiveEquals("FOLDING"))
            #expect(ascii.tmuxPredicate.contains("window_name"))
            #expect(!ascii.isFullyLowered)

            // Either way the answer is the one the client computes.
            let local = try await server.windows().filter(wide)
            let lowered = try await server.windows(where: wide)
            #expect(lowered.map(\.id) == local.map(\.id))
            #expect(local.map(\.name) == ["ÜBER"])
        }
    }

    /// Tree shapes, not just field types.
    ///
    /// The differential cases above vary the *operation*; every expression they
    /// build is a comparison or a one-level and/or over one. A degenerate
    /// branch is a different axis, and it is the one that hid a predicate which
    /// excluded rows the expression matched.
    @Test("a degenerate branch lowers to what it actually means")
    func degenerateBranchesLowerSoundly() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "foo")
            let named = try FilterExpr<Session>.where(\.name, .equals("foo"))
            let emptyOr = FilterExpr<Session>.or([])
            let emptyAnd = FilterExpr<Session>.and([])

            // `.or([])` matches nothing and `.and([])` matches everything.
            #expect(emptyOr.tmuxPredicate == "0")
            #expect(emptyOr.isFullyLowered)
            #expect(emptyAnd.tmuxPredicate == "1")
            #expect(emptyAnd.isFullyLowered)

            for expression: FilterExpr<Session> in [
                emptyOr, emptyAnd,
                .not(emptyOr), .not(emptyAnd),
                .and([emptyOr, named]), .or([emptyOr, named]),
                .and([emptyAnd, named]), .or([emptyAnd, named]),
                // The shape that dropped a row: a negated conjunction whose
                // always-false branch was lowered as always-true.
                .not(.and([emptyOr, named])),
                .not(.or([emptyAnd, named])),
                .not(.not(named)),
                .and([.and([]), .or([])]),
            ] {
                let local = try await server.sessions().filter(expression)
                let lowered = try await server.sessions(where: expression)
                #expect(
                    lowered.map(\.id) == local.map(\.id),
                    """
                    predicate: \(expression.tmuxPredicate) exact=\(expression.isFullyLowered)
                    tmux: \(lowered.map(\.name))
                    local: \(local.map(\.name))
                    """
                )
            }
        }
    }

    @Test("a literal tmux cannot compare byte for byte is decided at home")
    func unicodeAndHashLiteralsStayLocal() async throws {
        try await withTmuxServer { server in
            try await pinWindowNames(server)
            let session = try await server.newSession(named: "unicode")
            // Swift reads these two as one string; tmux reads five bytes and
            // six. Comparing them in tmux would drop a row Swift keeps, so
            // such a literal must not reach the predicate at all.
            let precomposed = "caf\u{e9}"
            let decomposed = "cafe\u{301}"
            #expect(precomposed == decomposed)

            // tmux keeps the run of hashes before a `[`, because `#[` opens a
            // style, so no encoding of a literal `#` is right everywhere.
            for name in [decomposed, "a#[b", "plain#hash"] {
                _ = try await server.newWindow(in: session, named: name)
            }

            for stored in try await server.windows().map(\.name) {
                let equals = try FilterExpr<Window>.where(\.name, .equals(stored))
                let expressions: [FilterExpr<Window>] = [equals, .not(equals)]
                if !FilterLowering.comparableAsBytes(stored) {
                    #expect(equals.tmuxPredicate == "1", "\(stored.debugDescription) lowered")
                    #expect(!equals.isFullyLowered)
                }
                for expression in expressions {
                    let local = try await server.windows().filter(expression)
                    let lowered = try await server.windows(where: expression)
                    #expect(
                        lowered.map(\.id) == local.map(\.id),
                        "disagreement on \(stored.debugDescription)"
                    )
                }
            }
        }
    }

    @Test("a glob is pushed down but never negated")
    func globsAreNotExact() throws {
        // tmux globs over bytes and Swift matches characters, so `e*` finds the
        // `e` inside a decomposed accent where hasPrefix("e") does not. The
        // predicate may admit that extra row; negating it would drop a real one.
        for operation: FilterOperator<String> in [
            .contains("a"), .hasPrefix("a"), .hasSuffix("a"),
            .caseInsensitiveEquals("a"), .caseInsensitiveContains("a"),
        ] {
            let expression = try FilterExpr<Window>.where(\.name, operation)
            #expect(expression.tmuxPredicate.contains("window_name"))
            #expect(!expression.isFullyLowered)
            #expect(FilterExpr.not(expression).tmuxPredicate == "1")
        }
        // Equality on an ASCII literal is exact, so it may be negated.
        let equals = try FilterExpr<Window>.where(\.name, .equals("a"))
        #expect(equals.isFullyLowered)
        #expect(FilterExpr.not(equals).tmuxPredicate != "1")
    }

    @Test("escaping works on scalars, not on grapheme clusters")
    func escapingHandlesCombiningMarks() {
        // `}` followed by a combining mark is a single Character that equals
        // neither `}` nor anything else, so a switch over characters walks past
        // a brace tmux still reads as the end of the expansion.
        let brace = "}\u{301}"
        #expect(brace.count == 1)
        #expect(brace.first != "}")
        #expect(
            Array(FilterLowering.escaped(brace).unicodeScalars) == ["#", "}", "\u{301}"],
            "the brace must be escaped even though it is not the first Character"
        )
        #expect(FilterLowering.globLiteral("*\u{301}") == "[*]\u{301}")
    }

    @Test("a regular expression is left out of the predicate but still applied")
    func regularExpressionsStayLocal() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "regex")
            _ = try await server.newWindow(in: session, named: "alpha")
            _ = try await server.newWindow(in: session, named: "beta")

            let pattern = try RegexPattern("^al")
            let expression = try FilterExpr<Window>.where(\.name, .matches(pattern))

            // Nothing to push down, so tmux is asked for everything...
            #expect(expression.tmuxPredicate == "1")
            #expect(!expression.isFullyLowered)
            // ...and the answer is still exactly right.
            let matched = try await server.windows(where: expression)
            #expect(matched.map(\.name) == ["alpha"])
        }
    }

    @Test("an unlowerable branch does not narrow the other side of an or")
    func disjunctionWithAnUnlowerableBranchStaysOpen() throws {
        let regex = try FilterExpr<Window>.where(\.name, .matches(RegexPattern("^a")))
        let exact = try FilterExpr<Window>.where(\.name, .equals("beta"))

        // An `or` cannot narrow past a branch it cannot evaluate: excluding
        // rows the regex might have matched would lose them for good.
        #expect(FilterExpr.or([regex, exact]).tmuxPredicate == "1")
        // An `and` may keep whichever side it does understand.
        #expect(FilterExpr.and([regex, exact]).tmuxPredicate.contains("window_name"))
        // Negating an approximation would under-approximate, so it is refused.
        #expect(FilterExpr.not(regex).tmuxPredicate == "1")
        #expect(FilterExpr.not(exact).tmuxPredicate.hasPrefix("#{==:#{==:"))
    }

    @Test("negation avoids the operator tmux 3.2a does not have")
    func negationDoesNotUseTheBangModifier() throws {
        let exact = try FilterExpr<Window>.where(\.name, .equals("x"))
        let predicate = FilterExpr.not(exact).tmuxPredicate
        // `#{!:...}` expands to nothing on 3.2a, which would silently match
        // every row rather than none.
        #expect(!predicate.contains("#{!:"))
        #expect(predicate.contains("#{==:"))
    }

    @Test("escaping neutralises every character tmux reads as syntax")
    func escapingCoversFormatSyntax() {
        #expect(FilterLowering.escaped("a,b") == "a#,b")
        #expect(FilterLowering.escaped("a}b") == "a#}b")
        #expect(FilterLowering.escaped("a#b") == "a##b")
        // `#` first, or escaping the comma would then have its own `#` escaped.
        #expect(FilterLowering.escaped("#,") == "###,")
        #expect(FilterLowering.globLiteral("a*b?c[d]") == "a[*]b[?]c[[]d[]]")
        // fnmatch reads a backslash as its own escape, so such a pattern is
        // refused rather than mis-escaped.
        #expect(FilterLowering.globLiteral("back\\slash") == nil)
    }
}
