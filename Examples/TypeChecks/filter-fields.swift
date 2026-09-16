import LibTmux

func typedFields() -> [FilterExpr<Pane>] {
    [
        .where(Pane.FilterFields.id, .equals(PaneID(rawValue: "%0")!)),
        .where(Pane.FilterFields.index, .isIn([0, 1])),
        .where(Pane.FilterFields.currentCommand, .contains("vim")),
        .where(Pane.FilterFields.currentPath, .hasPrefix("/src")),
        .where(Pane.FilterFields.isActive, .equals(true)),
        .where(Pane.FilterFields.isDead, .equals(false)),
        .where(Pane.FilterFields.modeCount, .equals(0)),
        .where(Pane.FilterFields.isSynchronized, .equals(false)),
        .where(Pane.FilterFields.windowID, .equals(WindowID(rawValue: "@0")!)),
    ]
}

func otherRoots() {
    let _: [FilterExpr<Session>] = [
        .where(Session.FilterFields.id, .equals(SessionID(rawValue: "$0")!)),
        .where(Session.FilterFields.name, .hasPrefix("build")),
        .where(Session.FilterFields.windowCount, .equals(2)),
        .where(Session.FilterFields.isAttached, .equals(false)),
    ]
    let _: [FilterExpr<Window>] = [
        .where(Window.FilterFields.id, .equals(WindowID(rawValue: "@0")!)),
        .where(Window.FilterFields.name, .equals("editor")),
        .where(Window.FilterFields.paneCount, .equals(2)),
    ]
    let _: [FilterExpr<Client>] = [
        .where(Client.FilterFields.name, .contains("client")),
        .where(Client.FilterFields.tty, .hasPrefix("/dev/")),
        .where(Client.FilterFields.isControlMode, .equals(true)),
        .where(Client.FilterFields.sessionID, .equals(SessionID(rawValue: "$0")!)),
    ]
}

func sendable<T: Sendable>(_ value: T) {}

func sendingFields() {
    sendable(Pane.FilterFields.currentCommand)
    sendable(typedFields())
}
