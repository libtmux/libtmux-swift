import KeyPathBakeoff

func invalidRelationOperatorOnScalar() throws {
    let operation: FilterOperator<String> = .some(
        try FilterExpr<RelatedPane>.where(\.command, .eq("nvim"))
    )
    let expression = try FilterExpr<Pane>.where(
        \.title,
        operation
    )
    _ = expression
}
