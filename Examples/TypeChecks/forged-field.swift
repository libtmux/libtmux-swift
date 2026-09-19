import LibTmux

func invalidFilter() {
    let _ = FilterField<Pane, Int>("pane.width")
}
