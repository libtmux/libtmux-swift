import Foundation
import KeyPathBakeoff

struct EvaluationOnlyRoot: QueryRecord {
    static let queryModel = ModelID(rawValue: "fixture.model.001")
    let querySnapshot = QuerySnapshot.record(
        model: queryModel,
        fields: [:],
        relations: [:]
    )
}

func invalidEvaluationRootWire() throws {
    let expression = FilterExpr<EvaluationOnlyRoot>.all([])
    _ = try JSONEncoder().encode(expression)
}
