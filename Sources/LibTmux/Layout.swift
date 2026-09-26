extension Server {
    /// Checks layouts and their required pane counts before changing tmux.
    ///
    /// Custom layouts require a valid checksum, nonempty tree and enough pane
    /// cells. Geometry and pruning remain tmux's responsibility. Empty batches
    /// perform no I/O unless cancelled; each supplied layout must be nonempty.
    ///
    /// Unique named abbreviations follow the running daemon. Only an unbound
    /// direct endpoint with no daemon uses the configured client's version.
    /// Transport, decode and cancellation failures are preserved.
    public func validateLayouts(
        _ layouts: [(layout: String, paneCount: Int)]
    ) async throws(TmuxError) {
        try await validateLayouts(layouts, guarding: nil)
    }

    func validateLayouts(
        _ layouts: [(layout: String, paneCount: Int)], guarding window: Window?
    ) async throws(TmuxError) {
        if Task.isCancelled { throw .cancelled }
        let beforeMirrors = TmuxVersion(major: 3, minor: 4)
        let withMirrors = TmuxVersion(major: 3, minor: 5)
        var sensitive: [(layout: String, paneCount: Int)] = []
        for item in layouts {
            if Task.isCancelled { throw .cancelled }
            let before = LayoutSyntax.accepts(
                item.layout, version: beforeMirrors, panes: item.paneCount)
            let after = LayoutSyntax.accepts(
                item.layout, version: withMirrors, panes: item.paneCount)
            guard before || after else {
                throw .invocationFailed(reason: "Invalid window layout or pane count.")
            }
            if before != after { sensitive.append(item) }
        }
        if Task.isCancelled { throw .cancelled }
        guard !sensitive.isEmpty else { return }
        let version = try await layoutVersion(guarding: window)
        for item in sensitive {
            if Task.isCancelled { throw .cancelled }
            guard LayoutSyntax.accepts(item.layout, version: version, panes: item.paneCount) else {
                throw .invocationFailed(reason: "Invalid window layout for tmux \(version).")
            }
        }
    }

    private func layoutVersion(guarding window: Window?) async throws(TmuxError) -> TmuxVersion {
        // A load asks here at the command, at the builder and once per window,
        // and the daemon's answer does not change under one endpoint. Over a
        // connection the probe is also what shows the connection is still there.
        if connection == nil, let recorded = await recordedDaemonVersion() { return recorded }
        let command = TmuxCommand("display-message", ["-p", "#{version}"])
        let reply: TmuxReply
        if let window {
            reply = try await runGuarded(command, by: [.window(window)])
        } else if connection != nil {
            reply = try await run(command)
        } else {
            reply = try await run(command, launchEnvironment: ["LC_ALL": "C"])
        }
        if reply.isSuccess && reply.standardError.isEmpty {
            guard let version = TmuxVersion(parsing: reply.text) else {
                throw .invocationFailed(reason: "Could not read the running tmux version.")
            }
            if connection == nil { await recordDaemonVersion(version) }
            return version
        }
        guard window == nil, connection == nil, isColdLayoutEndpoint(reply) else {
            throw .commandFailed(
                command: command.name, exitCode: reply.exitCode, reason: reply.errorText)
        }
        return try await version()
    }

    private func isColdLayoutEndpoint(_ reply: TmuxReply) -> Bool {
        guard reply.exitCode == 1, reply.standardOutput.isEmpty else { return false }
        let reason = reply.errorText
        guard !reason.contains("\n") else { return false }
        if case let .socketPath(path) = endpoint {
            return reason == "no server running on \(path)"
                || reason == "error connecting to \(path) (No such file or directory)"
                || reason == "error connecting to \(path) (Connection refused)"
        }
        return reason.hasPrefix("no server running on /")
            || (reason.hasPrefix("error connecting to /")
                && (reason.hasSuffix(" (No such file or directory)")
                    || reason.hasSuffix(" (Connection refused)")))
    }
}

/// Whether any supported tmux release would accept `layout` for `panes`
/// panes.
///
/// Pure syntax, so a caller can tell a defect in its own document from a
/// release difference without a round trip: a string every release refuses is
/// wrong wherever it is loaded, while one only some releases accept still has
/// to be put to the running daemon.
package func acceptsLayoutSyntax(_ layout: String, panes: Int) -> Bool {
    LayoutSyntax.accepts(layout, version: TmuxVersion(major: 3, minor: 4), panes: panes)
        || LayoutSyntax.accepts(layout, version: TmuxVersion(major: 3, minor: 5), panes: panes)
}

// Native saved-layout syntax; tmux retains geometry correction and pruning.
enum LayoutSyntax {
    static func accepts(_ layout: String, version: TmuxVersion, panes: Int) -> Bool {
        guard !layout.isEmpty, panes > 0 else { return false }
        var names = [
            "even-horizontal", "even-vertical", "main-horizontal", "main-vertical", "tiled",
        ]
        if version >= TmuxVersion(major: 3, minor: 5) {
            names += ["main-horizontal-mirrored", "main-vertical-mirrored"]
        }
        if names.contains(layout) || names.filter({ $0.hasPrefix(layout) }).count == 1 {
            return true
        }

        let bytes = Array(layout.utf8)
        guard bytes.count > 5, bytes[4] == Character(",").asciiValue,
            bytes.prefix(4).allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }),
            let expected = UInt16(String(decoding: bytes.prefix(4), as: UTF8.self), radix: 16)
        else { return false }
        let body = Array(bytes.dropFirst(5))
        let checksum = body.reduce(UInt16(0)) { sum, byte in
            ((sum >> 1) | (sum << 15)) &+ UInt16(byte)
        }
        guard checksum == expected else { return false }
        var parser = LayoutParser(bytes: body)
        return parser.cell(depth: 0) && parser.offset == body.count && parser.leaves >= panes
    }
}

private struct LayoutParser {
    let bytes: [UInt8]
    var offset = 0
    var leaves = 0

    mutating func take(_ character: Character) -> Bool {
        guard offset < bytes.count, bytes[offset] == character.asciiValue else { return false }
        offset += 1
        return true
    }

    mutating func number() -> Bool {
        let start = offset
        var value: UInt32 = 0
        while offset < bytes.count, (48...57).contains(bytes[offset]) {
            let digit = UInt32(bytes[offset] - 48)
            guard value <= (UInt32.max - digit) / 10 else { return false }
            value = value * 10 + digit
            offset += 1
        }
        return offset > start
    }

    mutating func cell(depth: Int) -> Bool {
        guard depth <= 256, number(), take("x"), number(), take(","), number(), take(","), number()
        else { return false }
        let saved = offset
        if take(",") {
            // Without pane IDs, the comma instead starts the next cell.
            if !number() || (offset < bytes.count && bytes[offset] == Character("x").asciiValue) {
                offset = saved
            }
        }
        let closing: Character
        if take("{") {
            closing = "}"
        } else if take("[") {
            closing = "]"
        } else {
            leaves += 1
            return true
        }
        guard cell(depth: depth + 1) else { return false }
        while take(",") {
            guard cell(depth: depth + 1) else { return false }
        }
        return take(closing)
    }
}
