import LibTmux

/// Rejects unsafe layout syntax before tmux can mutate a workspace.
/// Geometry correction and pruning remain tmux's responsibility.
package enum WorkspaceLayout {
    package static func validate(_ workspaces: [Workspace], on server: Server)
        async throws(TmuxError)
    {
        let windows = workspaces.flatMap(\.windows).filter { !($0.layout ?? "").isEmpty }
        let beforeMirrors = TmuxVersion(major: 3, minor: 4)
        let withMirrors = TmuxVersion(major: 3, minor: 5)
        var needsVersion: [WindowPlan] = []
        for window in windows {
            guard let layout = window.layout else { continue }
            let panes = max(1, window.panes.count)
            let before = accepts(layout, version: beforeMirrors, panes: panes)
            let after = accepts(layout, version: withMirrors, panes: panes)
            guard before || after else {
                throw .invocationFailed(reason: "Invalid window layout: \(layout)")
            }
            if before != after { needsVersion.append(window) }
        }
        guard !needsVersion.isEmpty else { return }
        let command = TmuxCommand("display-message", ["-p", "#{version}"])
        let reply = try await server.run(command, launchEnvironment: ["LC_ALL": "C"])
        let version: TmuxVersion
        if reply.isSuccess {
            guard let running = TmuxVersion(parsing: reply.text) else {
                throw .invocationFailed(reason: "Could not read the running tmux version.")
            }
            version = running
        } else {
            // Only ENOENT and ECONNREFUSED mean a client would start the daemon.
            let reason = reply.errorText
            guard
                reason.hasPrefix("no server running on ")
                    || (reason.hasPrefix("error connecting to ")
                        && reason.hasSuffix(" (No such file or directory)"))
            else {
                throw .commandFailed(
                    command: command.name, exitCode: reply.exitCode, reason: reason)
            }
            version = try await server.version()
        }
        for window in needsVersion {
            guard let layout = window.layout else { continue }
            guard accepts(layout, version: version, panes: max(1, window.panes.count)) else {
                throw .invocationFailed(
                    reason: "Invalid window layout for tmux \(version): \(layout)")
            }
        }
    }

    static func accepts(_ layout: String, version: TmuxVersion, panes: Int) -> Bool {
        guard !layout.isEmpty else { return true }
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
