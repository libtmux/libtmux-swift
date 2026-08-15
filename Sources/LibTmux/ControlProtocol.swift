/// One thing a control-mode server can say.
enum ControlEvent: Sendable, Hashable {
    /// A command's reply, bracketed by `%begin`/`%end` in the stream.
    ///
    /// The number is tmux's, and it matches the `%begin` that opened the block.
    /// It is what makes control mode attributable where a `;` list is not:
    /// output belongs to a numbered command rather than to one merged stream.
    case reply(ControlReply)

    /// Something that happened on the server, reported between blocks —
    /// `%session-changed`, `%output`, `%window-add`, and the rest.
    case notification(ControlNotification)

    /// The server closed the connection.
    case exited
}

public struct ControlReply: Sendable, Hashable {
    /// The number tmux stamped on this reply's block. Replies come back in the
    /// order their commands were sent, and this is what proves it rather than
    /// assuming it.
    public let number: Int
    /// What the command printed, one entry per line, with the block's own
    /// `%begin` and `%end` removed.
    public let lines: [String]
    /// tmux closed the block with `%error` rather than `%end`. The reason is in
    /// ``lines``, the same place a successful reply's output is.
    public let isError: Bool

    public init(number: Int, lines: [String], isError: Bool) {
        self.number = number
        self.lines = lines
        self.isError = isError
    }
}

public struct ControlNotification: Sendable, Hashable {
    /// The name without its `%`, so `%output` is `output`.
    public let name: String
    /// Everything after the name, unsplit. A notification's arguments are not
    /// uniformly shaped — `%output` carries arbitrary pane bytes — so splitting
    /// them here would be guessing.
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

/// Turns control-mode lines into events.
///
/// Feed it whole lines in order. It is a value: parsing a stream twice from the
/// same start yields the same events, which is what makes the protocol testable
/// without a live server.
struct ControlProtocolParser: Sendable {
    private var openBlock: (number: Int, lines: [String])?

    init() {}

    /// Consumes one line, returning an event if that line completed one.
    mutating func consume(_ line: String) -> ControlEvent? {
        guard line.hasPrefix("%") else {
            // Inside a block this is output; outside one tmux does not send
            // bare lines, and inventing an event for one would be a guess.
            openBlock?.lines.append(line)
            return nil
        }

        let (marker, rest) = splitOnFirstSpace(String(line.dropFirst()))
        switch marker {
        case "begin":
            openBlock = (number: blockNumber(rest) ?? 0, lines: [])
            return nil
        case "end", "error":
            guard let block = openBlock else { return nil }
            openBlock = nil
            return .reply(
                ControlReply(
                    number: block.number,
                    lines: block.lines,
                    isError: marker == "error"
                )
            )
        case "exit":
            return .exited
        default:
            // A notification can only arrive between blocks. Treating one as
            // block output would silently corrupt a command's reply.
            guard openBlock == nil else {
                openBlock?.lines.append(line)
                return nil
            }
            return .notification(
                ControlNotification(name: marker, arguments: rest)
            )
        }
    }

    /// Whether a command's reply is still being read.
    public var isInsideBlock: Bool { openBlock != nil }
}

/// `%begin <timestamp> <number> <flags>` — the number is the second field.
private func blockNumber(_ arguments: String) -> Int? {
    let fields = arguments.split(separator: " ")
    guard fields.count >= 2 else { return nil }
    return Int(fields[1])
}

private func splitOnFirstSpace(_ line: String) -> (String, String) {
    guard let space = line.firstIndex(of: " ") else { return (line, "") }
    return (
        String(line[line.startIndex..<space]),
        String(line[line.index(after: space)...])
    )
}
