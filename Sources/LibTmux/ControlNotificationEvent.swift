/// A control-mode notification, decoded.
///
/// ``ControlNotification`` keeps what tmux sent as a name and an unsplit
/// argument string, which is exact and forces every reader to parse. This is
/// the same notification in the terms a program acts on. Only the formats this
/// library has read in tmux's own source are decoded; anything else arrives as
/// ``ControlNotification/Event/unrecognized(_:)`` with the raw notification intact, so a newer tmux never
/// loses an event to an older parser.
///
/// ```swift
/// for try await notification in control.notifications {
///     if case let .output(pane, bytes) = notification.event {
///         print(pane, String(decoding: bytes, as: UTF8.self))
///     }
/// }
/// ```
extension ControlNotification {
    public enum Event: Sendable, Hashable {
        /// A pane wrote output. `bytes` are what the pane wrote, with tmux's
        /// escaping undone.
        case output(pane: PaneID, bytes: [UInt8])
        /// Output from a client with `pause-after` set, carrying how long it waited
        /// before being sent — the measure tmux pauses a pane by.
        case extendedOutput(pane: PaneID, ageMilliseconds: UInt64, bytes: [UInt8])
        /// tmux stopped sending a pane's output because it fell too far behind.
        case paused(pane: PaneID)
        /// tmux resumed a pane's output.
        case continued(pane: PaneID)
        case windowAdded(WindowID)
        case windowClosed(WindowID)
        case windowRenamed(WindowID, name: String)
        /// The active pane of a window changed.
        case windowPaneChanged(WindowID, pane: PaneID)
        /// The session this client is attached to changed.
        case sessionChanged(SessionID, name: String)
        case sessionRenamed(SessionID, name: String)
        /// The current window of a session changed.
        case sessionWindowChanged(SessionID, window: WindowID)
        /// A session was created or destroyed.
        case sessionsChanged
        /// A pane entered or left a mode such as copy mode.
        case paneModeChanged(pane: PaneID)
        case clientDetached(client: String)
        /// A notification whose format this library does not decode.
        case unrecognized(ControlNotification)
    }

    /// This notification, decoded. See ``ControlNotification/Event``.
    public var event: Event {
        Event(self)
    }
}

extension ControlNotification.Event {
    init(_ notification: ControlNotification) {
        let arguments = Substring(notification.arguments)
        self =
            switch notification.name {
            case "output": Self.output(arguments) ?? .unrecognized(notification)
            case "extended-output": Self.extendedOutput(arguments) ?? .unrecognized(notification)
            case "pause":
                PaneID(rawValue: String(arguments)).map { .paused(pane: $0) }
                    ?? .unrecognized(notification)
            case "continue":
                PaneID(rawValue: String(arguments)).map { .continued(pane: $0) }
                    ?? .unrecognized(notification)
            case "window-add":
                WindowID(rawValue: String(arguments)).map(Self.windowAdded)
                    ?? .unrecognized(notification)
            case "window-close":
                WindowID(rawValue: String(arguments)).map(Self.windowClosed)
                    ?? .unrecognized(notification)
            case "window-renamed":
                Self.named(arguments, WindowID.init(rawValue:))
                    .map { .windowRenamed($0.0, name: $0.1) } ?? .unrecognized(notification)
            case "window-pane-changed":
                Self.pair(arguments, WindowID.init(rawValue:), PaneID.init(rawValue:))
                    .map { .windowPaneChanged($0.0, pane: $0.1) } ?? .unrecognized(notification)
            case "session-changed":
                Self.named(arguments, SessionID.init(rawValue:))
                    .map { .sessionChanged($0.0, name: $0.1) } ?? .unrecognized(notification)
            case "session-renamed":
                Self.named(arguments, SessionID.init(rawValue:))
                    .map { .sessionRenamed($0.0, name: $0.1) } ?? .unrecognized(notification)
            case "session-window-changed":
                Self.pair(arguments, SessionID.init(rawValue:), WindowID.init(rawValue:))
                    .map { .sessionWindowChanged($0.0, window: $0.1) }
                    ?? .unrecognized(notification)
            case "sessions-changed": .sessionsChanged
            case "pane-mode-changed":
                PaneID(rawValue: String(arguments)).map { .paneModeChanged(pane: $0) }
                    ?? .unrecognized(notification)
            case "client-detached": .clientDetached(client: String(arguments))
            default: .unrecognized(notification)
            }
    }

    /// `%output %<pane> <data>`.
    private static func output(_ arguments: Substring) -> ControlNotification.Event? {
        let (head, data) = splitOnFirstSpace(arguments)
        guard let pane = PaneID(rawValue: String(head)) else { return nil }
        return .output(pane: pane, bytes: decodeOutput(data))
    }

    /// `%extended-output %<pane> <age> : <data>`.
    private static func extendedOutput(_ arguments: Substring) -> ControlNotification.Event? {
        let (head, rest) = splitOnFirstSpace(arguments)
        let (ageText, afterAge) = splitOnFirstSpace(rest)
        guard let pane = PaneID(rawValue: String(head)),
            let age = UInt64(ageText),
            afterAge.hasPrefix(": ")
        else { return nil }
        return .extendedOutput(
            pane: pane,
            ageMilliseconds: age,
            bytes: decodeOutput(afterAge.dropFirst(2))
        )
    }

    /// `<id> <name>`, where the name may itself contain spaces.
    private static func named<ID>(
        _ arguments: Substring,
        _ make: (String) -> ID?
    ) -> (ID, String)? {
        let (head, name) = splitOnFirstSpace(arguments)
        guard let id = make(String(head)) else { return nil }
        return (id, String(name))
    }

    /// `<first-id> <second-id>`.
    private static func pair<First, Second>(
        _ arguments: Substring,
        _ first: (String) -> First?,
        _ second: (String) -> Second?
    ) -> (First, Second)? {
        let (head, tail) = splitOnFirstSpace(arguments)
        guard let a = first(String(head)), let b = second(String(tail)) else { return nil }
        return (a, b)
    }

    private static func splitOnFirstSpace(_ text: Substring) -> (Substring, Substring) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (text[..<space], text[text.index(after: space)...])
    }

    /// Undoes tmux's control-mode escaping.
    ///
    /// `control_append_data` in tmux writes a byte below a space, and every
    /// backslash, as a backslash and three octal digits; every other byte,
    /// multibyte UTF-8 included, goes through as itself. A backslash therefore
    /// always starts an escape, which is what makes this unambiguous.
    static func decodeOutput(_ text: Substring) -> [UInt8] {
        let bytes = Array(text.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\"), index + 4 <= bytes.count,
                let value = octalByte(bytes[(index + 1)..<(index + 4)])
            {
                decoded.append(value)
                index += 4
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return decoded
    }

    private static func octalByte(_ digits: ArraySlice<UInt8>) -> UInt8? {
        guard digits.count == 3 else { return nil }
        var value = 0
        for digit in digits {
            guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "7") else { return nil }
            value = value * 8 + Int(digit - UInt8(ascii: "0"))
        }
        return value <= 0xFF ? UInt8(value) : nil
    }
}

extension ControlSession {
    /// Stops tmux sending a pane's output to this connection.
    ///
    /// Output that arrives while paused is not buffered for this client; tmux
    /// drops it. ``resumeOutput(of:)`` starts it again from the pane's current
    /// state. This is `refresh-client -A %<pane>:pause`, which acts on the
    /// client that sends it — this connection, and no other.
    public func pauseOutput(of pane: PaneID) async throws(TmuxError) {
        try await refreshPane(pane, action: "pause")
    }

    /// Resumes a pane's output after ``pauseOutput(of:)``, or after tmux paused
    /// it on its own for falling behind — which it announces as
    /// ``ControlNotification/Event/paused(pane:)``.
    public func resumeOutput(of pane: PaneID) async throws(TmuxError) {
        try await refreshPane(pane, action: "continue")
    }

    /// Asks tmux to pause any pane whose output this connection has not read
    /// within `lag`, instead of letting it pile up.
    ///
    /// Once set, output arrives as ``ControlNotification/Event/extendedOutput(pane:ageMilliseconds:bytes:)``,
    /// which carries how long it waited, and a pane that falls further behind
    /// than `lag` is paused and announced as
    /// ``ControlNotification/Event/paused(pane:)``. tmux measures the setting in
    /// whole seconds, so a fraction rounds up rather than to zero — `pause-after`
    /// with no value means pause on any lag at all, which is not what a caller
    /// asking for a short delay meant.
    public func pauseOutput(after lag: Duration) async throws(TmuxError) {
        let (seconds, attoseconds) = lag.components
        let whole = max(1, seconds + (attoseconds > 0 ? 1 : 0))
        let reply = try await send(
            TmuxCommand("refresh-client", ["-f", "pause-after=\(whole)"])
        )
        guard !reply.isError else {
            throw TmuxError.invocationFailed(reason: reply.lines.joined(separator: "\n"))
        }
    }

    private func refreshPane(_ pane: PaneID, action: String) async throws(TmuxError) {
        let reply = try await send(
            TmuxCommand("refresh-client", ["-A", "\(pane.rawValue):\(action)"])
        )
        guard !reply.isError else {
            throw TmuxError.invocationFailed(reason: reply.lines.joined(separator: "\n"))
        }
    }
}
