import LibTmux

func invalidFilter() {
    let _ = FilterExpr<Pane>.where(Session.FilterFields.name, .equals("main"))
}
