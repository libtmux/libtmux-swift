import LibTmux

func invalidFilter() {
    let _ = FilterExpr<Pane>.where(Pane.FilterFields.index, .contains("0"))
}
