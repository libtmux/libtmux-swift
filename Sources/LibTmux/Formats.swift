/// A tmux format field, and how to read what it produces.
///
/// The field's identity is its tmux name; a projection is built from these, and
/// a decoded row is addressed by name.
struct FormatField: Sendable, Hashable {
    let name: String
    let kind: Kind

    enum Kind: Sendable, Hashable {
        case text
        case integer
        /// An integer tmux may report as empty. A control-mode client has no
        /// terminal, so its dimensions are absent rather than zero.
        case optionalInteger
        case flag
    }

    init(_ name: String, _ kind: Kind = .text) {
        self.name = name
        self.kind = kind
    }
}

/// An ordered set of fields to request from one tmux listing.
struct FormatProjection: Sendable, Hashable {
    let fields: [FormatField]

    init(_ fields: [FormatField]) {
        self.fields = fields
    }

    /// U+241E SYMBOL FOR RECORD SEPARATOR. tmux expands each `#{}` exactly once
    /// and never escapes the result, so a field count is what makes a value
    /// containing this glyph recoverable: the row comes back over-long and is
    /// rejected, rather than silently shifting one object's value onto its
    /// neighbour.
    static let separator: Character = "\u{241E}"

    var template: String {
        fields
            .map { "#{\($0.name)}" }
            .joined(separator: String(FormatProjection.separator))
    }

    func decode(_ bytes: [UInt8]) throws(FormatDecodingError) -> [FormatRow] {
        var rows: [FormatRow] = []
        for (rowIndex, line) in framedLines(bytes).enumerated() {
            guard let text = String(bytes: line, encoding: .utf8) else {
                throw .invalidEncoding(rowIndex: rowIndex)
            }
            let raw = text.split(
                separator: FormatProjection.separator,
                omittingEmptySubsequences: false
            )
            guard raw.count == fields.count else {
                throw .fieldCountMismatch(
                    rowIndex: rowIndex,
                    expected: fields.count,
                    actual: raw.count
                )
            }
            var values: [String: FormatValue] = [:]
            for (field, value) in zip(fields, raw) {
                guard let decoded = FormatValue(String(value), kind: field.kind) else {
                    throw .invalidValue(
                        rowIndex: rowIndex,
                        field: field.name,
                        raw: String(value)
                    )
                }
                values[field.name] = decoded
            }
            rows.append(FormatRow(values: values))
        }
        return rows
    }
}

enum FormatValue: Sendable, Hashable {
    case text(String)
    case integer(Int)
    case optionalInteger(Int?)
    case flag(Bool)

    init?(_ raw: String, kind: FormatField.Kind) {
        switch kind {
        case .text:
            self = .text(raw)
        case .integer:
            guard let value = Int(raw) else { return nil }
            self = .integer(value)
        case .optionalInteger:
            if raw.isEmpty {
                self = .optionalInteger(nil)
                return
            }
            guard let value = Int(raw) else { return nil }
            self = .optionalInteger(value)
        case .flag:
            switch raw {
            case "0": self = .flag(false)
            case "1": self = .flag(true)
            default: return nil
            }
        }
    }
}

struct FormatRow: Sendable, Hashable {
    let values: [String: FormatValue]

    func text(_ field: FormatField) -> String {
        guard case let .text(value) = values[field.name] else { return "" }
        return value
    }

    func integer(_ field: FormatField) -> Int {
        guard case let .integer(value) = values[field.name] else { return 0 }
        return value
    }

    func optionalInteger(_ field: FormatField) -> Int? {
        guard case let .optionalInteger(value) = values[field.name] else {
            return nil
        }
        return value
    }

    func flag(_ field: FormatField) -> Bool {
        guard case let .flag(value) = values[field.name] else { return false }
        return value
    }
}

/// Splits on newlines, dropping only the terminator tmux writes after the last
/// row. A listing of zero objects and a listing of one object whose every field
/// is empty differ by exactly that byte.
private func framedLines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
    var remaining = bytes[...]
    if remaining.last == UInt8(ascii: "\n") {
        remaining = remaining.dropLast()
    }
    if remaining.isEmpty { return [] }
    return remaining.split(
        separator: UInt8(ascii: "\n"),
        omittingEmptySubsequences: false
    )
}

extension Server {
    /// Evaluates a tmux format and hands back what it printed.
    ///
    /// The listed types carry the fields worth modelling — a ``Pane`` knows its
    /// id, its size, and what is running in it. tmux publishes hundreds more,
    /// and this reaches any of them without the library having to name each
    /// one first:
    ///
    /// ```swift
    /// let tty = try await server.format("#{pane_tty}", for: pane)
    /// ```
    ///
    /// Ask for as many fields as you like in one template, separated by
    /// whatever the value cannot contain — a newline is the one separator to
    /// avoid, since a connection reads commands by line and refuses one.
    ///
    /// - Returns: what tmux printed, minus the newline it ends every answer
    ///   with, or `nil` when `target` no longer resolves.
    public func format(
        _ template: String,
        for session: Session
    ) async throws(TmuxError) -> String? {
        try await format(template, addressing: session.id)
    }

    /// Evaluates a tmux format against a window. See
    /// ``format(_:for:)-(String,Session)``.
    public func format(
        _ template: String,
        for window: Window
    ) async throws(TmuxError) -> String? {
        try await format(template, addressing: window.id)
    }

    /// Evaluates a tmux format against a pane. See
    /// ``format(_:for:)-(String,Session)``.
    public func format(
        _ template: String,
        for pane: Pane
    ) async throws(TmuxError) -> String? {
        try await format(template, addressing: pane.id)
    }

    /// Evaluates a tmux format against a target named by id.
    ///
    /// One `-t` serves every kind of target: tmux resolves the id to whichever
    /// object the format asks about, so only the caller distinguishes them.
    /// The typed overloads are the ones to reach for in Swift, where the
    /// object is already in hand. This is for an id that arrived from
    /// somewhere else — a command-line argument, or a request from another
    /// process — with no object to go with it.
    public func format(
        _ template: String,
        addressing target: String
    ) async throws(TmuxError) -> String? {
        // The pane id is asked alongside the caller's template, because tmux
        // answers a target that has gone exactly as it answers an empty field
        // — nothing, on a zero exit — and a pane id is never empty for a
        // target that resolves. Both travel in one command, so proving the
        // target costs no round trip.
        //
        // Separated by the record separator rather than a newline, because a
        // connection takes a command *line*: a newline inside an argument ends
        // the command there and leaves the rest to be read as another one.
        // Only the first separator divides the two, so a value carrying one of
        // its own arrives whole.
        let probeSeparator = FormatProjection.separator
        let reply = try await run(
            rawArguments: TmuxCommand(
                "display-message",
                ["-p", "-t", target, "#{pane_id}\(probeSeparator)" + template]
            ).argumentVector
        )
        guard reply.isSuccess else { return nil }
        var text = reply.text
        if text.hasSuffix("\n") { text.removeLast() }
        let parts = text.split(
            separator: probeSeparator,
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let probe = parts.first, !probe.isEmpty else { return nil }
        return parts.count > 1 ? String(parts[1]) : ""
    }

    /// Evaluates a tmux format against the server rather than any one object.
    ///
    /// Reaches the fields that describe the server itself — `#{pid}`,
    /// `#{version}`, `#{socket_path}` — and any format tmux resolves without a
    /// target.
    ///
    /// - Returns: what tmux printed, minus its trailing newline, or `nil` when
    ///   no server is listening. An unknown field name is not an error to tmux
    ///   and comes back as the empty string, the same as a field that is
    ///   legitimately empty.
    public func format(_ template: String) async throws(TmuxError) -> String? {
        let reply = try await run(
            rawArguments: TmuxCommand("display-message", ["-p", template])
                .argumentVector
        )
        guard reply.isSuccess else { return nil }
        var text = reply.text
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
