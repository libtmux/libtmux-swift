import Foundation
import Testing

@testable import LibTmux

private func makePane(
    id: String = "%0",
    index: Int = 0,
    command: String = "zsh",
    path: String = "/home/tony",
    isActive: Bool = true,
    windowID: String = "@0",
    sessionID: String = "$0"
) -> Pane {
    Pane(
        id: id,
        index: index,
        width: 80,
        height: 24,
        isActive: isActive,
        currentCommand: command,
        currentPath: path,
        windowID: windowID,
        sessionID: sessionID
    )
}

private let panes = [
    makePane(id: "%0", index: 0, command: "nvim"),
    makePane(id: "%1", index: 1, command: "zsh", isActive: false),
    makePane(id: "%2", index: 2, command: "vim", isActive: false),
    makePane(id: "%3", index: 3, command: "NVIM", isActive: false),
]

@Suite("filter expressions")
struct FilterExprTests {
    @Test("a key path lowers to its stable wire id")
    func keyPathLowersToItsWireID() throws {
        let expression = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim"]))
        guard case let .comparison(field, _) = expression else {
            Issue.record("expected a comparison")
            return
        }
        // The id is the contract, not the Swift property name.
        #expect(field == "pane.command")
    }

    @Test("membership selects in order and returns a plain array")
    func membershipSelectsInOrder() throws {
        let matched = try panes.filter(
            FilterExpr.where(\.currentCommand, .isIn(["nvim", "vim"]))
        )
        #expect(matched.map(\.id) == ["%0", "%2"])
    }

    @Test("case-insensitive matching is a distinct operator, not a default")
    func caseInsensitiveMatchingIsDistinct() throws {
        let exact = try panes.filter(FilterExpr.where(\.currentCommand, .equals("nvim")))
        #expect(exact.map(\.id) == ["%0"])

        let insensitive = try panes.filter(
            FilterExpr.where(\.currentCommand, .caseInsensitiveEquals("nvim"))
        )
        #expect(insensitive.map(\.id) == ["%0", "%3"])
    }

    @Test("a regular expression travels as pattern and flags")
    func regularExpressionTravelsAsData() throws {
        let expression = try FilterExpr<Pane>.where(
            \.currentCommand,
            .matches("^n?vim$", caseInsensitive: true)
        )
        guard case let .comparison(_, operation) = expression,
            case let .matches(pattern, caseInsensitive) = operation
        else {
            Issue.record("expected a regular-expression comparison")
            return
        }
        #expect(pattern == "^n?vim$")
        #expect(caseInsensitive)
        #expect(panes.filter(expression).map(\.id) == ["%0", "%2", "%3"])
    }

    @Test("conjunction, disjunction, and negation compose")
    func booleanCompositionWorks() throws {
        let active = try FilterExpr<Pane>.where(\.isActive, .equals(true))
        let vimish = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))

        #expect(panes.filter(.and([active, vimish])).map(\.id) == ["%0"])
        #expect(panes.filter(.or([active, vimish])).map(\.id) == ["%0", "%2"])
        #expect(panes.filter(.not(vimish)).map(\.id) == ["%1", "%3"])
    }

    @Test("an expression round-trips through JSON without a key path")
    func expressionRoundTripsThroughJSON() throws {
        let expression = try FilterExpr<Pane>.and([
            .where(\.currentCommand, .isIn(["nvim", "vim"])),
            .where(\.index, .equals(2)),
        ])
        let data = try JSONEncoder().encode(expression)
        let decoded = try JSONDecoder().decode(FilterExpr<Pane>.self, from: data)
        #expect(decoded == expression)
        #expect(panes.filter(decoded).map(\.id) == ["%2"])
    }

    @Test("exactlyOne tells absence apart from ambiguity")
    func exactlyOneDistinguishesItsFailures() throws {
        let one = try panes.exactlyOne(FilterExpr.where(\.currentCommand, .equals("zsh")))
        #expect(one.id == "%1")

        #expect(throws: CardinalityError.noMatch) {
            try panes.exactlyOne(FilterExpr.where(\.currentCommand, .equals("emacs")))
        }
        #expect(throws: CardinalityError.multipleMatches(count: 2)) {
            try panes.exactlyOne(FilterExpr.where(\.currentCommand, .isIn(["nvim", "vim"])))
        }
    }

    @Test("oneOrNil treats absence as an answer and ambiguity as an error")
    func oneOrNilOnlyThrowsOnAmbiguity() throws {
        #expect(try panes.oneOrNil(FilterExpr.where(\.currentCommand, .equals("emacs"))) == nil)
        #expect(throws: CardinalityError.multipleMatches(count: 2)) {
            try panes.oneOrNil(FilterExpr.where(\.currentCommand, .isIn(["nvim", "vim"])))
        }
    }

    @Test("every filterable field lowers and reads back")
    func everyFieldLowersAndReadsBack() {
        // Key paths cannot cross a test-argument boundary — they are not
        // `Sendable` — which is the same reason an expression lowers them away.
        let pairs: [(String, PartialKeyPath<Pane>)] = [
            ("pane.id", \Pane.id),
            ("pane.index", \Pane.index),
            ("pane.command", \Pane.currentCommand),
            ("pane.path", \Pane.currentPath),
            ("pane.active", \Pane.isActive),
            ("pane.windowID", \Pane.windowID),
            ("pane.sessionID", \Pane.sessionID),
        ]
        let pane = makePane()
        for (expected, keyPath) in pairs {
            #expect(Pane.filterFieldID(for: keyPath) == expected)
            #expect(Pane.filterValue(expected, of: pane) != nil)
        }
    }

    @Test("a property that is not filterable is rejected at construction")
    func unfilterablePropertyIsRejected() {
        #expect(throws: QueryConstructionError.unknownField) {
            try FilterExpr<Pane>.where(\.width, .equals(80))
        }
    }

    @Test("case-insensitive containment reaches what containment alone does not")
    func caseInsensitiveContainmentIgnoresCase() throws {
        let insensitive = try FilterExpr<Pane>.where(
            \.currentCommand, .caseInsensitiveContains("vim")
        )
        #expect(try panes.filter(insensitive).map(\.id) == ["%0", "%2", "%3"])

        let sensitive = try FilterExpr<Pane>.where(\.currentCommand, .contains("vim"))
        #expect(try panes.filter(sensitive).map(\.id) == ["%0", "%2"])
    }

    @Test("case-insensitive containment round-trips as its own operator")
    func caseInsensitiveContainmentRoundTrips() throws {
        let expression = try FilterExpr<Pane>.where(
            \.currentCommand, .caseInsensitiveContains("VIM")
        )
        let data = try JSONEncoder().encode(expression)
        let decoded = try JSONDecoder().decode(FilterExpr<Pane>.self, from: data)
        #expect(try panes.filter(decoded).map(\.id) == ["%0", "%2", "%3"])
    }
}
