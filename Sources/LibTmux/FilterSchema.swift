/// The filtering vocabulary, as a document.
///
/// A `FilterExpr` names fields by wire id, which is only useful to another
/// language if that language can learn what the ids are. This is that document:
/// versioned, `Codable`, and generated from the same registry the Swift API
/// lowers through, so a TypeScript, Rust, or CLI consumer reads the vocabulary
/// rather than guessing it.
public struct FilterSchema: Sendable, Hashable, Codable {
    /// Bumped when the document's *shape* changes. Adding a field or an alias
    /// does not bump it; those are additive and old readers keep working.
    public static let version = 1

    /// The ``version`` this document was written with, so a reader can tell
    /// whether it understands the shape before trying to use it.
    public let schemaVersion: Int
    /// One entry per filterable type, named as a client would ask for it.
    public let models: [Model]

    /// The filterable fields of one type.
    public struct Model: Sendable, Hashable, Codable {
        /// What a client calls this type — `pane`, `session`, and so on.
        public let name: String
        /// Every field a filter may name on it.
        public let fields: [Field]
    }

    /// One filterable field, and every name that reaches it.
    public struct Field: Sendable, Hashable, Codable {
        /// The stable id a `FilterExpr` carries.
        public let id: String
        /// What kind of literal the field compares against, so a client can
        /// reject a mismatch before sending one.
        public let type: ValueType
        /// Other names that resolve to this field — a Swift property name, or
        /// a name an older release used. Aliases exist so a rename never
        /// invalidates a stored expression.
        public let aliases: [String]
    }

    /// The kinds of value a field can hold. Deliberately three: tmux reports
    /// everything as text, and these are the only distinctions a filter has to
    /// make to compare correctly.
    public enum ValueType: String, Sendable, Hashable, Codable {
        case text
        case integer
        case flag
    }

    /// The vocabulary this build understands.
    public static var current: FilterSchema {
        FilterSchema(
            schemaVersion: version,
            models: [
                Model(name: "session", fields: Session.filterSchemaFields),
                Model(name: "window", fields: Window.filterSchemaFields),
                Model(name: "pane", fields: Pane.filterSchemaFields),
                Model(name: "client", fields: Client.filterSchemaFields),
            ]
        )
    }

    /// The field an id or alias names, within one model.
    public func field(named name: String, in model: String) -> Field? {
        guard let model = models.first(where: { $0.name == model }) else { return nil }
        return model.fields.first { $0.id == name || $0.aliases.contains(name) }
    }
}

extension Session {
    static let filterSchemaFields: [FilterSchema.Field] = [
        .init(id: "session.id", type: .text, aliases: ["id", "session_id"]),
        .init(id: "session.name", type: .text, aliases: ["name", "session_name"]),
        .init(
            id: "session.windowCount",
            type: .integer,
            aliases: ["windowCount", "session_windows"]
        ),
        .init(
            id: "session.attached",
            type: .flag,
            aliases: ["attached", "isAttached", "session_attached"]
        ),
    ]
}

extension Window {
    static let filterSchemaFields: [FilterSchema.Field] = [
        .init(id: "window.id", type: .text, aliases: ["id", "window_id"]),
        .init(id: "window.name", type: .text, aliases: ["name", "window_name"]),
        .init(id: "window.index", type: .integer, aliases: ["index", "window_index"]),
        .init(
            id: "window.paneCount",
            type: .integer,
            aliases: ["paneCount", "window_panes"]
        ),
        .init(
            id: "window.active",
            type: .flag,
            aliases: ["active", "isActive", "window_active"]
        ),
        .init(id: "window.sessionID", type: .text, aliases: ["sessionID", "session_id"]),
    ]
}

extension Pane {
    static let filterSchemaFields: [FilterSchema.Field] = [
        .init(id: "pane.id", type: .text, aliases: ["id", "pane_id"]),
        .init(id: "pane.index", type: .integer, aliases: ["index", "pane_index"]),
        .init(
            id: "pane.command",
            type: .text,
            aliases: ["currentCommand", "command", "pane_current_command"]
        ),
        .init(
            id: "pane.path",
            type: .text,
            aliases: ["currentPath", "path", "pane_current_path"]
        ),
        .init(
            id: "pane.active",
            type: .flag,
            aliases: ["active", "isActive", "pane_active"]
        ),
        .init(id: "pane.windowID", type: .text, aliases: ["windowID", "window_id"]),
        .init(id: "pane.sessionID", type: .text, aliases: ["sessionID", "session_id"]),
    ]
}

extension Client {
    static let filterSchemaFields: [FilterSchema.Field] = [
        .init(id: "client.name", type: .text, aliases: ["name", "client_name"]),
        .init(id: "client.tty", type: .text, aliases: ["tty", "client_tty"]),
        .init(
            id: "client.controlMode",
            type: .flag,
            aliases: ["controlMode", "isControlMode", "client_control_mode"]
        ),
        .init(id: "client.sessionID", type: .text, aliases: ["sessionID", "session_id"]),
    ]
}
