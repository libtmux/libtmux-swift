/// A supported filter field and its comparison value type.
///
/// Choose a field from a model's `FilterFields` namespace. Descriptors store
/// only a stable wire id, so they can cross tasks without retaining key paths.
/// Use ``FilterExpr/comparison(field:operation:)`` and
/// ``FilterExpr/validate()`` for dynamically supplied fields.
public struct FilterField<Root: Filterable, Value>: Sendable {
    /// The stable id encoded by a comparison using this field.
    public let id: String

    fileprivate init(_ id: String) {
        self.id = id
    }
}

/// The filterable surface of each model.
///
/// Descriptors, key paths and value lookups share wire ids. Renaming a Swift
/// property must not change the ids encoded in configurations and requests.

extension Session: Filterable {
    /// Supported fields for typed filter construction.
    public enum FilterFields {
        public static let id = FilterField<Session, SessionID>("session.id")
        public static let name = FilterField<Session, String>("session.name")
        public static let windowCount = FilterField<Session, Int>("session.windowCount")
        public static let isAttached = FilterField<Session, Bool>("session.attached")
    }

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
    /// Supported fields for typed filter construction.
    public enum FilterFields {
        public static let id = FilterField<Window, WindowID>("window.id")
        public static let name = FilterField<Window, String>("window.name")
        public static let paneCount = FilterField<Window, Int>("window.paneCount")
    }

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
    /// Supported fields for typed filter construction.
    public enum FilterFields {
        public static let id = FilterField<Pane, PaneID>("pane.id")
        public static let index = FilterField<Pane, Int>("pane.index")
        public static let currentCommand = FilterField<Pane, String>("pane.command")
        public static let currentPath = FilterField<Pane, String>("pane.path")
        public static let isActive = FilterField<Pane, Bool>("pane.active")
        public static let isDead = FilterField<Pane, Bool>("pane.dead")
        public static let modeCount = FilterField<Pane, Int>("pane.modeCount")
        public static let isSynchronized = FilterField<Pane, Bool>("pane.synchronized")
        public static let windowID = FilterField<Pane, WindowID>("pane.windowID")
    }

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
    /// Supported fields for typed filter construction.
    public enum FilterFields {
        public static let name = FilterField<Client, String>("client.name")
        public static let tty = FilterField<Client, String>("client.tty")
        public static let isControlMode = FilterField<Client, Bool>("client.controlMode")
        public static let sessionID = FilterField<Client, SessionID>("client.sessionID")
    }

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
