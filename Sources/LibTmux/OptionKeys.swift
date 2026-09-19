/// How one Swift type is written into, and read back from, a tmux option.
///
/// tmux keeps every option as text and prints it back the same way, so a typed
/// option is a spelling in both directions. `Bool`, `Int` and `String` conform,
/// and so does any `String`-backed enum that declares conformance, which is how
/// a choice option gets a type:
///
/// ```swift
/// enum StatusPosition: String, TmuxOptionValue { case top, bottom }
///
/// extension TmuxOptionKey<StatusPosition> {
///     static var statusPosition: Self { Self("status-position", table: .session) }
/// }
/// ```
///
/// tmux arbitrates a choice: a value one release does not know is refused by
/// that release, so an enum listing only what every supported release accepts
/// is the one that cannot be refused.
public protocol TmuxOptionValue: Sendable {
    /// The value tmux's text spells, or `nil` if it spells none.
    init?(tmuxOptionText text: String)
    /// The text that sets this value.
    var tmuxOptionText: String { get }
}

/// A flag. tmux accepts several spellings but prints only `on` and `off`.
extension Bool: TmuxOptionValue {
    public init?(tmuxOptionText text: String) {
        switch text {
        case "on": self = true
        case "off": self = false
        default: return nil
        }
    }

    public var tmuxOptionText: String { self ? "on" : "off" }
}

extension Int: TmuxOptionValue {
    public init?(tmuxOptionText text: String) {
        self.init(text)
    }

    public var tmuxOptionText: String { String(self) }
}

extension String: TmuxOptionValue {
    public init?(tmuxOptionText text: String) {
        self = text
    }

    public var tmuxOptionText: String { self }
}

extension TmuxOptionValue where Self: RawRepresentable, RawValue == String {
    public init?(tmuxOptionText text: String) {
        self.init(rawValue: text)
    }

    public var tmuxOptionText: String { rawValue }
}

/// The kind of table tmux keeps one of its own options in.
///
/// For its own options tmux takes the table from the option's name and ignores
/// the flag that would pick one. Naming the wrong table is therefore not
/// refused, and it does not reach the global table either:
/// `set-option -s mouse on` exits 0 and turns the mouse on for whichever
/// session tmux considers current. A key records its table so a typed call can
/// refuse that before tmux sees it.
public enum TmuxOptionTable: Sendable, Hashable, Codable {
    /// The one server table: `exit-empty`.
    case server
    /// The global session table, which each session can override: `mouse`.
    case session
    /// The global window table, which each window can override:
    /// `automatic-rename`.
    case window
    /// A window option that each pane can also override:
    /// `synchronize-panes`.
    case pane

    /// The table a typed call reaches when it names no scope.
    var globalScope: OptionScope {
        switch self {
        case .server: .server
        case .session: .globalSession
        case .window, .pane: .globalWindow
        }
    }

    /// Whether `scope` addresses a table that holds this kind of option.
    func holds(_ scope: OptionScope) -> Bool {
        switch (self, scope) {
        case (.server, .server),
            (.session, .globalSession), (.session, .session),
            (.window, .globalWindow), (.window, .window),
            (.pane, .globalWindow), (.pane, .window), (.pane, .pane):
            true
        default:
            false
        }
    }
}

/// A tmux option, the type of its value, and the table it lives in.
///
/// ```swift
/// try await server.setOption(.mouse, to: true)
/// let limit = try await server.option(.historyLimit)  // Int?
/// ```
///
/// A call that names no scope reaches the key's global table. A scope whose
/// table cannot hold the option is refused with
/// ``TmuxError/rejectedLocally(reason:)``, because tmux would not refuse it:
/// it would set the option on a session or window the caller never named.
///
/// Declare your own the way the library declares its keys. A user option, one
/// whose name begins with `@`, can live in any table:
///
/// ```swift
/// extension TmuxOptionKey<Bool> {
///     static var deployLocked: Self { Self("@deploy-locked", table: .server) }
/// }
/// ```
public struct TmuxOptionKey<Value>: Sendable, Hashable {
    /// The option's name as tmux spells it.
    public let name: String
    /// The table the option lives in.
    public let table: TmuxOptionTable

    public init(_ name: String, table: TmuxOptionTable) {
        self.name = name
        self.table = table
    }

    /// The scope a call reaches: the one asked for, or the global table.
    func scope(resolving scope: OptionScope?) throws(TmuxError) -> OptionScope {
        guard let scope else { return table.globalScope }
        guard table.holds(scope) else {
            throw .rejectedLocally(
                reason:
                    "\(name) is a \(table) option, and \(scope.tableDescription) does not hold "
                    + "one; tmux would accept the set and apply it somewhere this call did not name"
            )
        }
        return scope
    }
}

extension TmuxOptionKey<Bool> {
    /// Whether tmux takes mouse input.
    public static var mouse: Self { Self("mouse", table: .session) }

    /// Whether keys typed into one pane go to every pane in its window.
    public static var synchronizePanes: Self { Self("synchronize-panes", table: .pane) }

    /// Whether tmux names a window after the program running in it.
    public static var automaticRename: Self { Self("automatic-rename", table: .window) }

    /// Whether the server exits once its last session is gone.
    public static var exitEmpty: Self { Self("exit-empty", table: .server) }
}

extension TmuxOptionKey<Int> {
    /// How many lines of scrollback a new pane keeps.
    public static var historyLimit: Self { Self("history-limit", table: .session) }

    /// The index a session's first window takes.
    public static var baseIndex: Self { Self("base-index", table: .session) }
}

extension TmuxOptionKey<[Int: String]> {
    /// Which environment variables tmux copies from a client that attaches.
    public static var updateEnvironment: Self {
        Self("update-environment", table: .session)
    }

    /// One element of the array, read and written like a string option.
    ///
    /// ```swift
    /// try await server.setOption(TmuxOptionKey.updateEnvironment[3], to: "SSH_AUTH_SOCK")
    /// ```
    ///
    /// The type is spelled out because a chain starting with a bare
    /// `.updateEnvironment` must end at the same key type it started from.
    /// Unsetting an element removes it and leaves the others at their
    /// indices.
    public subscript(index: Int) -> TmuxOptionKey<String> {
        TmuxOptionKey<String>("\(name)[\(index)]", table: table)
    }
}
