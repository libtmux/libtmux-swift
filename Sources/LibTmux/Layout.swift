import Foundation

extension Server {
    /// Checks layouts and their required pane counts before changing tmux.
    ///
    /// Custom layouts require a valid checksum, nonempty tree and enough pane
    /// cells. Geometry and pruning remain tmux's responsibility. Empty batches
    /// perform no I/O unless cancelled; each supplied layout must be nonempty.
    ///
    /// Unique named abbreviations follow the running daemon. Only an endpoint
    /// with no daemon uses the configured executable's version. A release
    /// below the supported floor, like transport and cancellation failures,
    /// is thrown.
    public func validateLayouts(
        _ layouts: [(layout: String, paneCount: Int)]
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
            let document = LayoutSyntax.accepts(
                item.layout, version: .jsonLayouts, panes: item.paneCount)
            guard before || after || document else {
                throw .invocationFailed(reason: "Invalid window layout or pane count.")
            }
            // A layout only some releases take has to be put to the daemon's.
            if before != after || (document && !before) { sensitive.append(item) }
        }
        if Task.isCancelled { throw .cancelled }
        guard !sensitive.isEmpty else { return }
        let version = try await daemonVersion()
        for item in sensitive {
            if Task.isCancelled { throw .cancelled }
            guard LayoutSyntax.accepts(item.layout, version: version, panes: item.paneCount) else {
                throw .invocationFailed(reason: "Invalid window layout for tmux \(version).")
            }
        }
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
    [TmuxVersion(major: 3, minor: 4), TmuxVersion(major: 3, minor: 5), .jsonLayouts]
        .contains { LayoutSyntax.accepts(layout, version: $0, panes: panes) }
}

extension TmuxVersion {
    /// The earliest build measured to report `#{window_layout}` as JSON, a
    /// release candidate that ranks just below the 3.8 release itself.
    static let jsonLayouts = TmuxVersion(major: 3, minor: 8, build: "rc2")
}

// Native saved-layout syntax; tmux retains geometry correction and pruning.
enum LayoutSyntax {
    static func accepts(_ layout: String, version: TmuxVersion, panes: Int) -> Bool {
        guard !layout.isEmpty, panes > 0 else { return false }
        // From 3.8 a window's layout is a JSON document, and `select-layout`
        // takes the same document back. The geometry stays tmux's to judge.
        if layout.hasPrefix("{") {
            return version >= .jsonLayouts && acceptsJSON(layout, panes: panes)
        }
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

extension LayoutSyntax {
    private static func acceptsJSON(_ layout: String, panes: Int) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: Data(layout.utf8)),
            let document = root as? [String: Any],
            document["V"] as? Int == 2,
            let tree = document["L"] as? [String: Any]
        else { return false }
        var leaves = 0
        func accepts(_ node: [String: Any], depth: Int) -> Bool {
            guard depth <= 256, let kind = node["t"] as? String else { return false }
            switch kind {
            case "p":
                leaves += 1
                return true
            case "v", "h":
                guard let children = node["c"] as? [[String: Any]], !children.isEmpty else {
                    return false
                }
                return children.allSatisfy { accepts($0, depth: depth + 1) }
            default:
                return false
            }
        }
        return accepts(tree, depth: 0) && leaves >= panes
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
