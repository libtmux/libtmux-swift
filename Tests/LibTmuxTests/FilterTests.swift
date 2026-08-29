import Foundation
import Testing

@testable import LibTmux

private let filterIncarnation = ServerIncarnation(
    endpoint: .socketPath("/tmp/libtmux-swift-test/filter-fixture"),
    socketPath: "/tmp/libtmux-swift-test/filter-fixture",
    processID: 1,
    startedAt: 1
)

private func makePane(
    id: PaneID = "%0",
    index: Int = 0,
    command: String = "zsh",
    path: String = "/home/tony",
    isActive: Bool = true,
    windowID: WindowID = "@0"
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
        incarnation: filterIncarnation
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

    @Test("typed ids build equality and membership filters")
    func typedIDsBuildEqualityAndMembershipFilters() throws {
        let session = Session(
            id: "$7", name: "typed", windowCount: 1, isAttached: false,
            createdAt: 0, incarnation: filterIncarnation
        )
        let window = Window(
            id: "@4", name: "typed", paneCount: 1, width: 80, height: 24,
            incarnation: filterIncarnation
        )
        let pane = makePane(id: "%9", windowID: window.id)
        let client = Client(
            name: "typed", tty: "", processID: 2, width: nil, height: nil,
            isControlMode: true, sessionID: session.id, incarnation: filterIncarnation
        )

        let sessionID = try FilterExpr<Session>.where(\.id, .equals(session.id))
        let clientSessionID = try FilterExpr<Client>.where(
            \.sessionID, .isIn([session.id])
        )
        let windowID = try FilterExpr<Window>.where(\.id, .equals(window.id))
        let paneWindowID = try FilterExpr<Pane>.where(\.windowID, .isIn([window.id]))
        let paneID = try FilterExpr<Pane>.where(\.id, .equals(pane.id))
        let paneIDs = try FilterExpr<Pane>.where(\.id, .isIn([pane.id]))

        #expect(try sessionID.matches(session))
        #expect(try clientSessionID.matches(client))
        #expect(try windowID.matches(window))
        #expect(try paneWindowID.matches(pane))
        #expect(try paneID.matches(pane))
        #expect(try paneIDs.matches(pane))
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
        let pattern = try RegexPattern(
            "^n?vim$",
            options: [.caseInsensitive]
        )
        let expression = try FilterExpr<Pane>.where(
            \.currentCommand,
            .matches(pattern)
        )
        guard case let .comparison(_, operation) = expression,
            case let .matches(traveled) = operation
        else {
            Issue.record("expected a regular-expression comparison")
            return
        }
        #expect(traveled == pattern)
        let decoded = try JSONDecoder().decode(
            FilterExpr<Pane>.self,
            from: JSONEncoder().encode(expression)
        )
        #expect(decoded == expression)
        #expect(try panes.filter(decoded).map(\.id) == ["%0", "%2", "%3"])
    }

    @Test("conjunction, disjunction, and negation compose")
    func booleanCompositionWorks() throws {
        let active = try FilterExpr<Pane>.where(\.isActive, .equals(true))
        let vimish = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))

        #expect(try panes.filter(.and([active, vimish])).map(\.id) == ["%0"])
        #expect(try panes.filter(.or([active, vimish])).map(\.id) == ["%0", "%2"])
        #expect(try panes.filter(.not(vimish)).map(\.id) == ["%1", "%3"])
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
        #expect(try panes.filter(decoded).map(\.id) == ["%2"])
    }

    @Test("validation rejects dynamically impossible comparisons")
    func validationRejectsImpossibleComparisons() throws {
        let expressions: [FilterExpr<Pane>] = [
            .comparison(field: "pane.index", operation: .contains("3")),
            .comparison(field: "pane.active", operation: .equals(.text("true"))),
        ]

        for expression in expressions {
            let data = try JSONEncoder().encode(expression)
            let decoded = try JSONDecoder().decode(FilterExpr<Pane>.self, from: data)
            #expect(throws: FilterValidationError.self) { try decoded.validate() }
        }
    }

    @Test("exactlyOne tells absence apart from ambiguity")
    func exactlyOneDistinguishesItsFailures() throws {
        let one = try panes.exactlyOne(FilterExpr.where(\.currentCommand, .equals("zsh")))
        #expect(one.id == "%1")

        #expect(throws: FilterSelectionError.cardinality(.noMatch)) {
            try panes.exactlyOne(FilterExpr.where(\.currentCommand, .equals("emacs")))
        }
        #expect(throws: FilterSelectionError.cardinality(.multipleMatches(count: 2))) {
            try panes.exactlyOne(FilterExpr.where(\.currentCommand, .isIn(["nvim", "vim"])))
        }
    }

    @Test("oneOrNil treats absence as an answer and ambiguity as an error")
    func oneOrNilOnlyThrowsOnAmbiguity() throws {
        #expect(try panes.oneOrNil(FilterExpr.where(\.currentCommand, .equals("emacs"))) == nil)
        #expect(throws: FilterSelectionError.cardinality(.multipleMatches(count: 2))) {
            try panes.oneOrNil(FilterExpr.where(\.currentCommand, .isIn(["nvim", "vim"])))
        }
    }

    @Test("pattern work limits propagate through filter evaluation")
    func patternWorkLimitsPropagate() throws {
        let members = String(repeating: "a", count: 4_000)
        let expression = try FilterExpr<Pane>.where(
            \.currentCommand,
            .matches(try RegexPattern("[\(members)]"))
        )
        let input = makePane(command: String(repeating: "z", count: 4_000))

        #expect(
            throws: RegexMatchError.workLimitExceeded(
                maximum: RegexPattern.defaultMaximumWork
            )
        ) {
            try expression.matches(input)
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
