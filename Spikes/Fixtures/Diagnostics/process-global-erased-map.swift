import KeyPathBakeoff

enum ProcessGlobalErasedMap {
    static let fields: [AnyKeyPath: FieldID] = [
        \Pane.command: .paneCommand,
        \Pane.title: .paneTitle,
    ]
}
