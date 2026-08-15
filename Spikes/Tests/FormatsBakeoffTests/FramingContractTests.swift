import Testing

@testable import FormatsBakeoff
@testable import SpikeSupport

private let nameField = FormatField(
    id: FormatFieldID("session.name"),
    name: "session_name",
    kind: .text
)
private let widthField = FormatField(
    id: FormatFieldID("session.width"),
    name: "session_width",
    kind: .integer
)
private let attachedField = FormatField(
    id: FormatFieldID("session.attached"),
    name: "session_attached",
    kind: .flag
)

private let projection = FormatProjection(
    scope: .session,
    fields: [nameField, widthField, attachedField]
)

private let separator = String(RawSeparatorFraming.separator)

/// Values a user can put in a session or window name, a pane title, or a user
/// option. Each one has broken a delimiter-based encoding somewhere.
let adversarialValues: [(label: String, value: String)] = [
    ("empty", ""),
    ("space", "a b"),
    ("tab", "a\tb"),
    ("backslash", #"a\b"#),
    ("single-quote", "a'b"),
    ("double-quote", #"a"b"#),
    ("semicolon", "a;b"),
    ("dollar", "a$b"),
    ("format-like", "#{session_name}"),
    ("hash", "a#b"),
    ("brace", "a}b"),
    ("newline-escape", #"a\nb"#),
    ("unicode", "å∫ç"),
    ("separator-glyph-neighbour", "\u{241D}\u{241F}"),
]

private func framedReply(_ rows: [[String]], terminated: Bool = true) -> ProcessReply {
    var text = rows.map { $0.joined(separator: separator) }.joined(separator: "\n")
    if terminated, !rows.isEmpty { text += "\n" }
    return ProcessReply(
        standardOutput: Array(text.utf8),
        standardError: [],
        termination: .exited(0)
    )
}

private func decode(_ reply: ProcessReply) -> StrictListingResult<FormatRow> {
    ProjectionDecoder.strictListing(
        reply: reply,
        projection: projection,
        framing: RawSeparatorFraming()
    )
}

private func requireRows(
    _ result: StrictListingResult<FormatRow>,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> [FormatRow] {
    guard case let .rows(rows) = result else {
        Issue.record("expected rows, got \(result)", sourceLocation: sourceLocation)
        throw FramingContractError.unexpectedResult
    }
    return rows
}

private enum FramingContractError: Error {
    case unexpectedResult
}

@Suite("raw separator framing contract")
struct FramingContractTests {
    @Test("the template projects each field once, in order")
    func templateProjectsEachFieldOnceInOrder() {
        #expect(
            RawSeparatorFraming().template(for: projection)
                == "#{session_name}\(separator)#{session_width}\(separator)"
                + "#{session_attached}"
        )
    }

    @Test("a listing with no objects is not a row of empty fields")
    func emptyListingIsNotAnEmptyRow() throws {
        let empty = ProcessReply(
            standardOutput: [],
            standardError: [],
            termination: .exited(0)
        )
        #expect(try requireRows(decode(empty)).isEmpty)

        let allEmptyRow = framedReply([["", "0", "0"]])
        #expect(try requireRows(decode(allEmptyRow)).count == 1)
    }

    @Test("an unterminated final row still decodes")
    func unterminatedFinalRowDecodes() throws {
        let rows = try requireRows(
            decode(framedReply([["one", "80", "1"]], terminated: false))
        )
        #expect(rows.count == 1)
        #expect(rows[0][nameField.id] == .text("one"))
    }

    @Test("rows keep their order and their trailing empty fields")
    func rowsKeepOrderAndTrailingEmptyFields() throws {
        let rows = try requireRows(
            decode(
                framedReply([
                    ["first", "80", "1"],
                    ["", "0", "0"],
                    ["last", "24", "1"],
                ])
            )
        )
        #expect(rows.count == 3)
        #expect(rows[0][nameField.id] == .text("first"))
        #expect(rows[1][nameField.id] == .text(""))
        #expect(rows[1][attachedField.id] == .flag(false))
        #expect(rows[2][nameField.id] == .text("last"))
    }

    @Test(
        "every representable value round-trips",
        arguments: adversarialValues.map(\.value)
    )
    func everyRepresentableValueRoundTrips(_ value: String) throws {
        let rows = try requireRows(decode(framedReply([[value, "80", "1"]])))
        #expect(rows.count == 1)
        #expect(rows[0][nameField.id] == .text(value))
    }

    @Test("a value carrying the separator is a field-count mismatch, not a shift")
    func separatorInAValueIsReportedRatherThanShiftingFields() {
        let reply = framedReply([["a\(separator)b", "80", "1"]])
        guard case let .decodingFailure(error) = decode(reply) else {
            Issue.record("expected a decoding failure")
            return
        }
        #expect(
            error == .fieldCountMismatch(rowIndex: 0, expected: 3, actual: 4)
        )
    }

    @Test("a short row names the row it failed on")
    func shortRowNamesItsIndex() {
        let reply = framedReply([["ok", "80", "1"], ["short", "80"]])
        guard case let .decodingFailure(error) = decode(reply) else {
            Issue.record("expected a decoding failure")
            return
        }
        #expect(
            error == .fieldCountMismatch(rowIndex: 1, expected: 3, actual: 2)
        )
    }

    @Test("a value carrying a newline splits into rows the count then rejects")
    func newlineInAValueIsRejected() {
        let reply = framedReply([["a\nb", "80", "1"]])
        guard case .decodingFailure = decode(reply) else {
            Issue.record("expected a decoding failure")
            return
        }
    }

    @Test("invalid UTF-8 is a typed decoding failure, not a transport failure")
    func invalidUTF8IsATypedDecodingFailure() {
        var bytes = Array("ok\(separator)80\(separator)1\n".utf8)
        bytes.insert(contentsOf: [0xFF, 0xFE], at: 0)
        let reply = ProcessReply(
            standardOutput: bytes,
            standardError: [],
            termination: .exited(0)
        )
        guard case let .decodingFailure(error) = decode(reply) else {
            Issue.record("expected a decoding failure")
            return
        }
        #expect(error == .invalidEncoding(rowIndex: 0))
    }

    @Test("a value that is not its declared kind names the field")
    func mistypedValueNamesItsField() {
        let reply = framedReply([["ok", "eighty", "1"]])
        guard case let .decodingFailure(error) = decode(reply) else {
            Issue.record("expected a decoding failure")
            return
        }
        #expect(
            error
                == .invalidValue(
                    rowIndex: 0,
                    field: widthField.id,
                    raw: "eighty"
                )
        )
    }

    @Test("a rejected tmux command stays a reply")
    func rejectedCommandStaysAReply() {
        let reply = ProcessReply(
            standardOutput: [],
            standardError: Array("no server running\n".utf8),
            termination: .exited(1)
        )
        guard case let .commandFailure(observed) = decode(reply) else {
            Issue.record("expected a command failure")
            return
        }
        #expect(observed == reply)
    }
}
