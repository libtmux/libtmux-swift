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
        case pane(String)
        /// Every pane in the attached session, including ones opened later.
        case allPanes
        /// One window, by id.
        case window(String)
        /// Every window in the attached session, including ones opened later.
        case allWindows

        var wireForm: String {
            switch self {
            case .attachedSession: ""
            case let .pane(id): id
            case .allPanes: "%*"
            case let .window(id): id
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
    public let sessionID: String
    /// Absent when the subscription's scope is a session.
    public let windowID: String?
    public let windowIndex: Int?
    /// Absent when the subscription's scope is a session or a window.
    public let paneID: String?
    /// What the format evaluates to now.
    public let value: String

    public init(
        name: String,
        sessionID: String,
        windowID: String? = nil,
        windowIndex: Int? = nil,
        paneID: String? = nil,
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
        func optional(_ index: Int) -> String? {
            let field = String(fields[index])
            return field == "-" ? nil : field
        }
        self.init(
            name: String(fields[0]),
            sessionID: String(fields[1]),
            windowID: optional(2),
            windowIndex: optional(3).flatMap(Int.init),
            paneID: optional(4),
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
