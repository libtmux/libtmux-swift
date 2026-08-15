import KeyPathBakeoff

func invalidStringOperatorOnInteger() throws {
    let operation: FilterOperator<Int> = .contains("8")
    let expression = try FilterExpr<Pane>.where(
        \.width,
        operation
    )
    _ = expression
}
