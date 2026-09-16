import LibTmux

func invalidFilter() {
    let _ = FilterExpr<Pane>.where(Pane.FilterFields.id, .equals(SessionID(rawValue: "$0")!))
}
