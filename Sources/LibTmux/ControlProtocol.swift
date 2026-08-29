import Foundation

struct ControlLineInput: Sendable {
    enum Event: Sendable, Hashable {
        case line(String)
        case failure(TmuxError)
    }

    static let maximumBytes = 2_000_000
    private var framer = BoundedLineFramer(maximumBytes: maximumBytes)

    mutating func append(_ data: Data) -> [Event] {
        map(framer.append(data))
    }

    mutating func finish() -> [Event] {
        guard framer.bufferedBytes == 0 else {
            _ = framer.finish()
            return [
                .failure(
                    .invocationFailed(reason: "control protocol ended with an incomplete line")
                )
            ]
        }
        return []
    }

    private func map(_ events: [BoundedLineFramer.Event]) -> [Event] {
        events.map { event in
            switch event {
            case let .line(line): .line(line)
            case .oversized:
                .failure(
                    .invocationFailed(
                        reason: "control protocol line exceeds \(Self.maximumBytes) bytes"
                    )
                )
            case .invalidUTF8:
                .failure(.invocationFailed(reason: "control protocol line is not UTF-8"))
            }
        }
    }
}

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

    /// The stream broke its own block framing.
    case protocolViolation(String)
}

public struct ControlReply: Sendable, Hashable {
    /// The number tmux stamped on this reply's block. Replies come back in the
    /// order their commands were sent, and this is what proves it rather than
    /// assuming it.
    public let number: Int
    /// What the command printed, one entry per line, with the block's own
    /// `%begin` and `%end` removed.
    public let lines: [String]
    let isControlCommand: Bool
    /// tmux closed the block with `%error` rather than `%end`. The reason is in
    /// ``lines``, the same place a successful reply's output is.
    public let isError: Bool

    public init(number: Int, lines: [String], isError: Bool) {
        self.init(
            number: number,
            lines: lines,
            isControlCommand: false,
            isError: isError
        )
    }

    init(number: Int, lines: [String], isControlCommand: Bool, isError: Bool) {
        self.number = number
        self.lines = lines
        self.isControlCommand = isControlCommand
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
    private var openBlock: (metadata: BlockMetadata, lines: [String])?

    init() {}

    /// Consumes one line, returning an event if that line completed one.
    mutating func consume(_ line: String) -> ControlEvent? {
        if var block = openBlock {
            if line.hasPrefix("%") {
                let (marker, rest) = splitOnFirstSpace(String(line.dropFirst()))
                if (marker == "end" || marker == "error"),
                    let metadata = blockMetadata(rest),
                    metadata == block.metadata
                {
                    openBlock = nil
                    return .reply(
                        ControlReply(
                            number: block.metadata.number,
                            lines: block.lines,
                            isControlCommand: block.metadata.isControlCommand,
                            isError: marker == "error"
                        )
                    )
                }
            }
            block.lines.append(line)
            openBlock = block
            return nil
        }

        guard line.hasPrefix("%") else {
            // Outside a block tmux does not send bare lines, and inventing an
            // event for one would be a guess.
            return nil
        }

        let (marker, rest) = splitOnFirstSpace(String(line.dropFirst()))
        switch marker {
        case "begin":
            guard let metadata = blockMetadata(rest) else {
                return .protocolViolation("malformed %begin metadata")
            }
            openBlock = (metadata: metadata, lines: [])
            return nil
        case "end", "error":
            guard let metadata = blockMetadata(rest) else {
                return .protocolViolation("malformed %\(marker) metadata")
            }
            return .protocolViolation(
                "unmatched %\(marker) for command \(metadata.number)"
            )
        case "exit":
            return .exited
        default:
            return .notification(
                ControlNotification(name: marker, arguments: rest)
            )
        }
    }

    /// Whether a command's reply is still being read.
    public var isInsideBlock: Bool { openBlock != nil }
}

/// `%begin <timestamp> <number> <flags>`.
private struct BlockMetadata: Sendable, Hashable {
    let timestamp: Int
    let number: Int
    let flags: Int

    var isControlCommand: Bool { flags != 0 }
}

private func blockMetadata(_ arguments: String) -> BlockMetadata? {
    let fields = arguments.split(separator: " ")
    guard fields.count == 3,
        let timestamp = Int(fields[0]),
        let number = Int(fields[1]),
        let flags = Int(fields[2])
    else {
        return nil
    }
    return BlockMetadata(timestamp: timestamp, number: number, flags: flags)
}

private func splitOnFirstSpace(_ line: String) -> (String, String) {
    guard let space = line.firstIndex(of: " ") else { return (line, "") }
    return (
        String(line[line.startIndex..<space]),
        String(line[line.index(after: space)...])
    )
}
