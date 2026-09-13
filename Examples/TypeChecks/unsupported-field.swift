import LibTmux

func invalidFilter() {
    let _ = FilterExpr<Pane>.where(Pane.FilterFields.width, .equals(80))
}
