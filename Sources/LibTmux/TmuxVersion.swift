import Foundation

/// A tmux release, ordered the way tmux numbers them.
///
/// The trailing letter is part of the version, not decoration: tmux 3.7 shipped
/// a `break-pane` crash that 3.7a reverted, so code that has to know which one
/// it is talking to needs `3.7 < 3.7a` to be true. Comparing on the numbers
/// alone would make those two equal and the question unanswerable.
public struct TmuxVersion: Sendable, Hashable, Comparable, Codable {
    /// The major version — `3` in `3.7a`.
    public let major: Int
    /// The minor version — `7` in `3.7a`.
    public let minor: Int
    /// The point release's letter — `a` in `3.7a` — empty when there is none.
    /// Ordered as tmux issues them, so no letter precedes `a` precedes `b`.
    public let pointRelease: String
    /// What tmux was built from when it is not a release: `master` for a git
    /// build, `openbsd` for the one in OpenBSD's base system. Absent otherwise.
    public let build: String?

    public init(major: Int, minor: Int, pointRelease: String = "", build: String? = nil) {
        self.major = major
        self.minor = minor
        self.pointRelease = pointRelease
        self.build = build
    }

    /// Reads what `tmux -V` prints.
    ///
    /// Returns `nil` rather than guessing: a version this cannot read is a tmux
    /// whose behaviour this library has no basis to predict, and defaulting to
    /// "probably recent" is how a workaround silently stops being applied.
    public init?(parsing text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("tmux ") { body = String(body.dropFirst(5)) }

        // `next-3.8` is tmux's own prefix for a pre-release; `3.4-master` and
        // `3.4-openbsd` are suffixes. Either way the tag is not the number.
        var build: String?
        if let dash = body.firstIndex(of: "-") {
            let before = String(body[body.startIndex..<dash])
            let after = String(body[body.index(after: dash)...])
            if Int(before.prefix(1)) == nil, !before.isEmpty {
                build = before
                body = after
            } else {
                build = after
                body = before
            }
        }

        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]) else { return nil }

        let tail = parts[1]
        let digits = tail.prefix { $0.isNumber }
        guard !digits.isEmpty, let minor = Int(digits) else { return nil }
        let letters = String(tail.dropFirst(digits.count))
        guard letters.allSatisfy({ $0.isLetter }) else { return nil }

        self.init(major: major, minor: minor, pointRelease: letters, build: build)
    }

    public static func < (lhs: TmuxVersion, rhs: TmuxVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.pointRelease)
            < (rhs.major, rhs.minor, rhs.pointRelease)
    }
}

extension TmuxVersion: CustomStringConvertible {
    public var description: String {
        let release = "\(major).\(minor)\(pointRelease)"
        return build.map { "\(release)-\($0)" } ?? release
    }
}

extension Server {
    /// Which tmux this server runs.
    ///
    /// Read from the binary rather than from a running daemon, so it answers
    /// before anything is started. A build this library cannot parse throws
    /// rather than reporting a version it guessed.
    public func version() async throws(TmuxError) -> TmuxVersion {
        let reply = try await run(rawArguments: ["-V"])
        guard let version = TmuxVersion(parsing: reply.text) else {
            throw .invocationFailed(
                reason: "could not read a tmux version from \(reply.text.debugDescription)"
            )
        }
        return version
    }
}
