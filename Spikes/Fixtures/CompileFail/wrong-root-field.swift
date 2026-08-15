import KeyPathBakeoff

func invalidRoot() throws {
    let expression = try FilterExpr<Pane>.where(
        \PaneSession.name,
        .eq("work")
    )
    _ = expression
}
