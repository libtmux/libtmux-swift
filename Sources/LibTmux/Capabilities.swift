/// What the tmux a server runs can actually do.
///
/// The library gates a handful of behaviours on the running release — the
/// mirrored layout presets arrived in 3.5, the JSON `window_layout` form in
/// 3.8 — and those gates were internal, so a caller wanting the same answer
/// compared version numbers itself and had to know which number meant what.
/// This is the same table, read once and named.
///
/// ```swift
/// if try await server.capabilities().jsonWindowLayout {
///     // `WindowLayout.custom(_:)` may carry the JSON form.
/// }
/// ```
///
/// Only the capabilities this library gates on are listed. A capability with
/// no gate behind it would be a claim nothing here checks, and the first
/// release to break it would break it silently.
public struct TmuxCapabilities: Sendable, Hashable, Codable {
    /// The release these answers describe.
    public let version: TmuxVersion

    /// Whether `main-vertical-mirrored` and `main-horizontal-mirrored` exist.
    ///
    /// From tmux 3.5. Below it they are not layout names at all, so a value
    /// naming one is refused rather than sent — an unknown layout takes the
    /// path that kills tmux 3.3 and 3.3a.
    public var mirroredLayoutPresets: Bool {
        version >= TmuxVersion(major: 3, minor: 5)
    }

    /// Whether `window_layout` is reported and accepted as JSON.
    ///
    /// From tmux 3.8. ``Server/selectLayout(_:_:)-(Window,WindowLayout)`` refuses a JSON-shaped
    /// layout below it, because applying one reached the daemon and crashed
    /// it rather than being rejected.
    public var jsonWindowLayout: Bool {
        version >= TmuxVersion(major: 3, minor: 8)
    }

    public init(version: TmuxVersion) {
        self.version = version
    }
}

extension Server {
    /// What the running tmux can do, in the terms this library gates on.
    ///
    /// One `display-message`, the same read ``version()`` makes.
    public func capabilities() async throws(TmuxError) -> TmuxCapabilities {
        TmuxCapabilities(version: try await version())
    }
}
