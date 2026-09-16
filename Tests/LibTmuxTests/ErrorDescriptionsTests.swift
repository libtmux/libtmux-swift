import Foundation
import LibTmux
import Testing

@Suite("error descriptions")
struct ErrorDescriptionsTests {
    @Test("Foundation preserves completed-command diagnostics")
    func foundationPreservesCommandDiagnostics() {
        let error = TmuxError.commandFailed(
            command: "list-panes", exitCode: 7, reason: "permission denied")
        let message = (error as any Error).localizedDescription
        #expect(message.contains("list-panes"))
        #expect(message.contains("7"))
        #expect(message.contains("permission denied"))
        #expect(message == String(describing: error))
        guard case let .commandFailed(command, code, reason) = error else {
            Issue.record("lost structured command failure")
            return
        }
        #expect(command == "list-panes" && code == 7 && reason == "permission denied")
    }

    @Test("decoded values stay available without entering descriptions")
    func decodedValuesStayOutOfDescriptions() {
        let error = FormatDecodingError.invalidValue(
            rowIndex: 4, field: "pane_width", raw: "private-pane-value")
        let wrapped = TmuxError.decodingFailed(error)
        for failure: any Error in [error, wrapped] {
            let message = String(describing: failure)
            #expect(!message.contains("private-pane-value"))
            #expect(message.contains("4"))
            #expect(message.contains("pane_width"))
            #expect(failure.localizedDescription == message)
        }
        guard case let .invalidValue(_, _, raw) = error else { return }
        #expect(raw == "private-pane-value")
    }

    @Test("predicate literals and regex sources stay out of descriptions")
    func predicateValuesStayOutOfDescriptions() {
        let validation = FilterValidationError.incompatibleOperation(
            field: "pane.index", type: .integer, operation: .contains("private-query-value"))
        let errors: [any Error] = [
            validation,
            QueryConstructionError.invalidOperation(validation),
            FilterLookupError.invalidRegularExpression("private-query-value"),
            FilterLookupError.valueNotOfFieldType("private-query-value"),
        ]
        for error in errors {
            #expect(!String(describing: error).contains("private-query-value"))
            #expect(!error.localizedDescription.contains("private-query-value"))
            #expect(error.localizedDescription == String(describing: error))
        }
        guard case let .incompatibleOperation(_, _, operation) = validation else { return }
        #expect(operation == .contains("private-query-value"))
    }

    @Test("nested failures retain the useful matching and cardinality context")
    func nestedDescriptionsRetainContext() {
        let matching = RegexMatchError.workLimitExceeded(maximum: 123)
        let errors: [any Error] = [
            matching,
            OutputWaitError.matching(matching),
            FilteredListingError.matching(matching),
            FilterSelectionError.matching(matching),
        ]
        for error in errors {
            #expect(error.localizedDescription.contains("123"))
            #expect(error.localizedDescription == String(describing: error))
        }
        let cardinality = FilterSelectionError.cardinality(.multipleMatches(count: 9))
        #expect(cardinality.localizedDescription.contains("9"))
        let regex = RegexCompileError.unterminatedGroup(offset: 11)
        #expect(regex.localizedDescription.contains("11"))
        #expect(regex.localizedDescription.lowercased().contains("group"))
    }
}
