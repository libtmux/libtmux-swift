import Foundation

/// A format tmux reports changes to, rather than being asked for.
///
/// `refresh-client -B` registers one against a control connection. tmux then
/// evaluates the format about once a second and sends
/// ``SubscriptionChange`` whenever the value differs from the last one it
/// sent — so "has the foreground command changed?" costs no commands, no
/// captures, and no scrollback at all.
///
/// Requires tmux 3.2 or later, which is this package's floor.
public struct FormatSubscription: Sendable, Hashable {
    /// What tmux evaluates the format against.
    public enum Scope: Sendable, Hashable {
        /// The session the connection attached to.
        case attachedSession
        /// One pane, by id.
        case pane(PaneID)
        /// Every pane in the attached session, including ones opened later.
        case allPanes
        /// One window, by id.
        case window(WindowID)
        /// Every window in the attached session, including ones opened later.
        case allWindows

        var wireForm: String {
            switch self {
            case .attachedSession: ""
            case let .pane(id): id.rawValue
            case .allPanes: "%*"
            case let .window(id): id.rawValue
            case .allWindows: "@*"
            }
        }
    }

    /// What changes are reported under, and what
    /// ``ControlSession/stopWatching(_:)`` names.
    public let name: String
    public let scope: Scope
    /// A tmux format, such as `#{pane_current_command}`.
    public let format: String

    public init(name: String, scope: Scope = .allPanes, format: String) {
        self.name = name
        self.scope = scope
        self.format = format
    }

    var argument: String { "\(name):\(scope.wireForm):\(format)" }
}

/// One report that a subscribed format's value changed.
///
/// tmux sends the value it changed *to*, not what it changed from, and sends
/// the current value once when the subscription is created. A watcher
/// therefore learns the starting value without asking for it.
public struct SubscriptionChange: Sendable, Hashable, Codable {
    /// Which ``FormatSubscription`` this belongs to.
    public let name: String
    public let sessionID: SessionID
    /// Absent when the subscription's scope is a session.
    public let windowID: WindowID?
    public let windowIndex: Int?
    /// Absent when the subscription's scope is a session or a window.
    public let paneID: PaneID?
    /// What the format evaluates to now.
    public let value: String

    public init(
        name: String,
        sessionID: SessionID,
        windowID: WindowID? = nil,
        windowIndex: Int? = nil,
        paneID: PaneID? = nil,
        value: String
    ) {
        self.name = name
        self.sessionID = sessionID
        self.windowID = windowID
        self.windowIndex = windowIndex
        self.paneID = paneID
        self.value = value
    }

    /// Reads a `%subscription-changed` notification, or `nil` for any other.
    ///
    /// The wire form is `name session window index pane [reserved...] : value`.
    /// tmux documents everything between the pane id and a lone `:` as
    /// reserved, so the `:` is what the value is found by rather than a field
    /// count that a later release would change.
    public init?(_ notification: ControlNotification) {
        guard notification.name == "subscription-changed" else { return nil }
        let fields = notification.arguments.split(
            separator: " ",
            omittingEmptySubsequences: false
        )
        guard let separator = fields.firstIndex(of: ":"), separator >= 5 else {
            return nil
        }
        func optionalID<ID: TmuxID>(_ index: Int, as _: ID.Type) -> ID?? {
            let field = String(fields[index])
            if field == "-" { return .some(nil) }
            guard let id = ID(rawValue: field) else { return nil }
            return .some(id)
        }
        func optionalIndex(_ index: Int) -> Int?? {
            let field = String(fields[index])
            if field == "-" { return .some(nil) }
            guard let value = Int(field), value >= 0 else { return nil }
            return .some(value)
        }
        guard
            let sessionID = SessionID(rawValue: String(fields[1])),
            let windowID = optionalID(2, as: WindowID.self),
            let windowIndex = optionalIndex(3),
            let paneID = optionalID(4, as: PaneID.self)
        else { return nil }
        self.init(
            name: String(fields[0]),
            sessionID: sessionID,
            windowID: windowID,
            windowIndex: windowIndex,
            paneID: paneID,
            value: fields[(separator + 1)...].joined(separator: " ")
        )
    }
}

extension ControlSession {
    /// Registers a format subscription on this connection.
    public func watch(_ subscription: FormatSubscription) async throws {
        let reply = try await send(
            TmuxCommand("refresh-client", ["-B", subscription.argument])
        )
        guard !reply.isError else {
            throw TmuxError.invocationFailed(reason: reply.lines.joined(separator: "\n"))
        }
    }

    /// Removes the subscription registered under `name`.
    ///
    /// tmux reads a `-B` argument with no scope and no format as a removal, so
    /// this is the same command with the rest left off.
    public func stopWatching(_ name: String) async throws {
        _ = try await send(TmuxCommand("refresh-client", ["-B", name]))
    }

    /// Every subscription change on this connection, optionally narrowed to
    /// one subscription's name.
    ///
    /// An observer of its own, like ``notifications``, so watching does not
    /// take notifications away from anything else reading the connection.
    public nonisolated func changes(named name: String? = nil) -> AsyncStream<
        SubscriptionChange
    > {
        let notifications = self.notifications
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let pump = Task {
                for await notification in notifications {
                    guard let change = SubscriptionChange(notification) else { continue }
                    guard name == nil || change.name == name else { continue }
                    continuation.yield(change)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}
