import Foundation
import Testing

@testable import LibTmux

private let pane = Pane(
    id: "%0",
    index: 3,
    width: 80,
    height: 24,
    isActive: true,
    currentCommand: "nvim",
    currentPath: "/src",
    windowID: "@1",
    sessionID: "$2"
)

@Suite("filter schema")
struct FilterSchemaTests {
    @Test("every advertised field is one the library can actually read")
    func advertisedFieldsAreReadable() {
        // The schema is a promise to other languages; a field it lists but the
        // reader does not know would be a filter that builds and never matches.
        for field in Pane.filterSchemaFields {
            #expect(
                Pane.filterValue(field.id, of: pane) != nil,
                Comment(rawValue: "pane schema advertises unreadable \(field.id)")
            )
        }
        for field in Session.filterSchemaFields {
            #expect(
                Session.filterValue(
                    field.id,
                    of: Session(
                        id: "$0", name: "n", windowCount: 1,
                        isAttached: false, createdAt: 0
                    )
                ) != nil
            )
        }
    }

    @Test("advertised types match what the reader returns")
    func advertisedTypesMatchTheReader() {
        for field in Pane.filterSchemaFields {
            guard let value = Pane.filterValue(field.id, of: pane) else { continue }
            switch (field.type, value) {
            case (.text, .text), (.integer, .integer), (.flag, .flag):
                break
            default:
                Issue.record("\(field.id) is advertised \(field.type) but read \(value)")
            }
        }
    }

    @Test("the document round-trips as JSON")
    func documentRoundTripsAsJSON() throws {
        let data = try JSONEncoder().encode(FilterSchema.current)
        let decoded = try JSONDecoder().decode(FilterSchema.self, from: data)
        #expect(decoded == FilterSchema.current)
        #expect(decoded.schemaVersion == FilterSchema.version)
        #expect(decoded.models.map(\.name) == ["session", "window", "pane", "client"])
    }

    @Test("a field resolves by id, by Swift name, and by tmux format name")
    func fieldResolvesByEveryAlias() {
        let schema = FilterSchema.current
        for name in ["pane.command", "currentCommand", "command", "pane_current_command"] {
            #expect(schema.field(named: name, in: "pane")?.id == "pane.command")
        }
        #expect(schema.field(named: "nonsense", in: "pane") == nil)
        #expect(schema.field(named: "pane.command", in: "session") == nil)
    }
}

@Suite("field lookups")
struct FilterLookupTests {
    private func parse(_ lookup: String) throws -> FilterExpr<Pane> {
        try FilterLookup.parse(lookup, as: Pane.self, model: "pane")
    }

    @Test("a lookup lowers to the same tree a key path builds")
    func lookupLowersToTheSameTree() throws {
        let fromText = try parse("command__contains=vim")
        let fromKeyPath = try FilterExpr<Pane>.where(\.currentCommand, .contains("vim"))
        // The text edge is sugar; it produces no shape the typed API cannot.
        #expect(fromText == fromKeyPath)
    }

    @Test("a lookup with no operator means equality")
    func bareLookupMeansEquality() throws {
        #expect(
            try parse("command=nvim")
                == FilterExpr<Pane>.where(\.currentCommand, .equals("nvim"))
        )
    }

    @Test("each Python operator maps to its typed counterpart")
    func operatorsMapToTheirCounterparts() throws {
        #expect(try parse("command__iexact=NVIM").matches(pane))
        #expect(try parse("command__startswith=nv").matches(pane))
        #expect(try parse("command__endswith=im").matches(pane))
        #expect(try parse("command__icontains=VI").matches(pane))
        #expect(try parse("command__in=vim,nvim").matches(pane))
        #expect(try parse("command__regex=^n.im$").matches(pane))
        #expect(try parse("command__iregex=^N.IM$").matches(pane))
        #expect(!(try parse("command__regex=^N.IM$").matches(pane)))
    }

    @Test("a value is read as the field's own type")
    func valueIsReadAsTheFieldsType() throws {
        #expect(try parse("index=3").matches(pane))
        #expect(!(try parse("index=4").matches(pane)))
        #expect(try parse("active=true").matches(pane))
        #expect(!(try parse("active=no").matches(pane)))

        #expect(throws: FilterLookupError.valueNotOfFieldType("three")) {
            try parse("index=three")
        }
    }

    @Test("an unusable lookup names what was wrong with it")
    func unusableLookupNamesItsProblem() {
        #expect(throws: FilterLookupError.missingValue) { try parse("command__contains") }
        #expect(throws: FilterLookupError.unknownField("nonsense")) {
            try parse("nonsense=x")
        }
        #expect(throws: FilterLookupError.unknownOperator("sounds_like")) {
            try parse("command__sounds_like=vim")
        }
    }

    @Test("a lookup can name a field the way tmux does")
    func lookupAcceptsTmuxFormatNames() throws {
        #expect(
            try parse("pane_current_command=nvim")
                == FilterExpr<Pane>.where(\.currentCommand, .equals("nvim"))
        )
    }
}
