import Foundation

/// A tmux release, ordered the way tmux numbers them.
///
/// The trailing letter is part of the version, not decoration: tmux 3.7 shipped
/// a `break-pane` crash that 3.7a reverted, so code that has to know which one
/// it is talking to needs `3.7 < 3.7a` to be true. Comparing on the numbers
/// alone would make those two equal and the question unanswerable.
///
/// `build` breaks the tie the other way: at the same `(major, minor,
/// pointRelease)`, a tagged build sorts below the untagged release it names,
/// so `next-3.9 < 3.9` while `3.8 < next-3.9` — a development build previews
/// the release, it is not equivalent to it. That is the answer this type
/// gives to the question a feature gate actually asks: a check written as
/// `version >= TmuxVersion(major: 3, minor: 9)` is **not** satisfied by
/// `next-3.9`, on purpose, because a feature `3.9` will ship can still be
/// half-landed in the build that only names it. A caller that means "some
/// build previewing 3.9, half-landed features and all" compares `build`
/// itself rather than relying on `<`.
///
/// The same rule applies to `openbsd`, not only to `next`/`master`: any tag
/// at a given number sorts below the plain release at that number, because a
/// vendored or forked build is not proven to behave like the release it
/// claims to be either. Two different tags at the same number order by the
/// tag's own text, which is arbitrary but keeps the relation total — nothing
/// in this library depends on that ordering; it exists so sorting a mixed
/// list never has to ask which of two builds "wins".
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
        let lhsKey = (lhs.major, lhs.minor, lhs.pointRelease)
        let rhsKey = (rhs.major, rhs.minor, rhs.pointRelease)
        guard lhsKey == rhsKey else { return lhsKey < rhsKey }
        // Same numbered release: nil (the plain release) sorts last, so any
        // tag — `next`, `master`, `openbsd` — sorts below it; two different
        // tags at the same number order by name, so the relation stays total
        // rather than leaving same-number, different-tag builds unordered.
        switch (lhs.build, rhs.build) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (lhsBuild?, rhsBuild?): return lhsBuild < rhsBuild
        }
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
