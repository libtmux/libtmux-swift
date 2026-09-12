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

            let ascii = try FilterExpr<Window>.where(\.name, .caseInsensitiveEquals("FOLDING"))
            #expect(ascii.isFullyLowered)

            // Either way the answer is the one the client computes.
            let local = try await server.windows().filter(wide)
            let lowered = try await server.windows(where: wide)
            #expect(lowered.map(\.id) == local.map(\.id))
            #expect(local.map(\.name) == ["ÜBER"])
        }
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
