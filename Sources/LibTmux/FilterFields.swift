/// The filterable surface of each model.
///
/// Every field appears twice on purpose — once to lower a key path to its id,
/// once to read that id back off a value. Both directions are `switch`-shaped
/// so a field added to one and forgotten in the other is a filter that builds
/// and never matches, which the round-trip tests catch.
///
/// The ids are spelled out rather than derived from the Swift property name.
/// They are what travels — into a config file, an MCP request, or a future tmux
/// `-f` predicate — so renaming a property must not renumber a wire schema.

extension Session: Filterable {
    public static func filterFieldType(_ id: String) -> FilterSchema.ValueType? {
        filterSchemaFields.first { $0.id == id }?.type
    }

    public static func filterFieldID(for keyPath: PartialKeyPath<Session>) -> String? {
        switch keyPath {
        case \Session.id: "session.id"
        case \Session.name: "session.name"
        case \Session.windowCount: "session.windowCount"
        case \Session.isAttached: "session.attached"
        default: nil
        }
    }

    public static func filterValue(_ id: String, of root: Session) -> FilterValue? {
        switch id {
        case "session.id": .text(root.id.rawValue)
        case "session.name": .text(root.name)
        case "session.windowCount": .integer(root.windowCount)
        case "session.attached": .flag(root.isAttached)
        default: nil
        }
    }

    public static func filterFormatField(_ id: String) -> String? {
        switch id {
        case "session.id": "session_id"
        case "session.name": "session_name"
        case "session.windowCount": "session_windows"
        case "session.attached": "session_attached"
        default: nil
        }
    }
}

extension Window: Filterable {
    public static func filterFieldType(_ id: String) -> FilterSchema.ValueType? {
        filterSchemaFields.first { $0.id == id }?.type
    }

    public static func filterFieldID(for keyPath: PartialKeyPath<Window>) -> String? {
        switch keyPath {
        case \Window.id: "window.id"
        case \Window.name: "window.name"
        case \Window.paneCount: "window.paneCount"
        default: nil
        }
    }

    public static func filterValue(_ id: String, of root: Window) -> FilterValue? {
        switch id {
        case "window.id": .text(root.id.rawValue)
        case "window.name": .text(root.name)
        case "window.paneCount": .integer(root.paneCount)
        default: nil
        }
    }

    public static func filterFormatField(_ id: String) -> String? {
        switch id {
        case "window.id": "window_id"
        case "window.name": "window_name"
        case "window.paneCount": "window_panes"
        default: nil
        }
    }
}

extension Pane: Filterable {
    public static func filterFieldType(_ id: String) -> FilterSchema.ValueType? {
        filterSchemaFields.first { $0.id == id }?.type
    }

    public static func filterFieldID(for keyPath: PartialKeyPath<Pane>) -> String? {
        switch keyPath {
        case \Pane.id: "pane.id"
        case \Pane.index: "pane.index"
        case \Pane.currentCommand: "pane.command"
        case \Pane.currentPath: "pane.path"
        case \Pane.isActive: "pane.active"
        case \Pane.isDead: "pane.dead"
        case \Pane.modeCount: "pane.modeCount"
        case \Pane.isSynchronized: "pane.synchronized"
        case \Pane.windowID: "pane.windowID"
        default: nil
        }
    }

    public static func filterValue(_ id: String, of root: Pane) -> FilterValue? {
        switch id {
        case "pane.id": .text(root.id.rawValue)
        case "pane.index": .integer(root.index)
        case "pane.command": .text(root.currentCommand)
        case "pane.path": .text(root.currentPath)
        case "pane.active": .flag(root.isActive)
        case "pane.dead": .flag(root.isDead)
        case "pane.modeCount": .integer(root.modeCount)
        case "pane.synchronized": .flag(root.isSynchronized)
        case "pane.windowID": .text(root.windowID.rawValue)
        default: nil
        }
    }

    public static func filterFormatField(_ id: String) -> String? {
        switch id {
        case "pane.id": "pane_id"
        case "pane.index": "pane_index"
        case "pane.active": "pane_active"
        case "pane.dead": "pane_dead"
        case "pane.modeCount": "pane_in_mode"
        case "pane.synchronized": "pane_synchronized"
        case "pane.command": "pane_current_command"
        case "pane.path": "pane_current_path"
        case "pane.windowID": "window_id"
        default: nil
        }
    }
}

extension Client: Filterable {
    public static func filterFieldType(_ id: String) -> FilterSchema.ValueType? {
        filterSchemaFields.first { $0.id == id }?.type
    }

    public static func filterFieldID(for keyPath: PartialKeyPath<Client>) -> String? {
        switch keyPath {
        case \Client.name: "client.name"
        case \Client.tty: "client.tty"
        case \Client.isControlMode: "client.controlMode"
        case \Client.sessionID: "client.sessionID"
        default: nil
        }
    }

    public static func filterValue(_ id: String, of root: Client) -> FilterValue? {
        switch id {
        case "client.name": .text(root.name)
        case "client.tty": .text(root.tty)
        case "client.controlMode": .flag(root.isControlMode)
        case "client.sessionID": .text(root.sessionID.rawValue)
        default: nil
        }
    }

    public static func filterFormatField(_ id: String) -> String? {
        switch id {
        case "client.name": "client_name"
        case "client.tty": "client_tty"
        case "client.controlMode": "client_control_mode"
        case "client.sessionID": "session_id"
        default: nil
        }
    }
}
