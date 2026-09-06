import Foundation

/// What the server tells a client about itself at `initialize`.
///
/// This is the only text every model sees before choosing a tool, so it carries
/// the decisions that go wrong most often: when tmux is *not* what was meant,
/// which of the four waits to reach for, and what is deliberately absent so
/// nothing is spent probing for it.
enum Instructions {
    /// Kept under the budget clients allocate for a server blurb. Past it some
    /// truncate, and what they lose is the tail.
    static let maximumBytes = 2048

    static func text(
        authority: ToolAuthority,
        waitCeiling: Duration,
        caller: CallerIdentity?
    ) -> String {
        var sections = required(authority: authority, waitCeiling: waitCeiling)

        // This belongs to the caller process, not to the server hierarchy.
        if let pane = caller?.paneID {
            sections.insert(
                """
                You run inside tmux pane \(pane). Kill tools refuse it without \
                force=true; list_panes marks it isCaller.
                """,
                at: min(1, sections.count)
            )
        }

        // Dropped from the end rather than truncated mid-sentence, and never
        // fatal: a blurb that outgrew its budget is a problem for the test that
        // measures it, not a reason to fail every client at initialize.
        while sections.count > 1,
            joined(sections).utf8.count > maximumBytes
        {
            sections.removeLast()
        }
        return joined(sections)
    }

    /// The sections, longest-lived first, so what drops under budget pressure
    /// is what a model can most easily do without.
    static func required(authority: ToolAuthority, waitCeiling: Duration) -> [String] {
        let available = Set(authority.resolve(TmuxTools.definitions).map(\.name))
        var sections = [
            """
            tmux via libtmux for Swift. Server > Session > Window > Pane. \
            Tool refs are process-local; refresh them after MCP restart.
            """,
            """
            TRIGGERS: tmux panes, windows, sessions; 'this terminal', 'send keys', \
            'scrollback', pane output.
            NOT FOR: browser tabs, editor splits (VS Code, Neovim), GUI windows \
            (i3, sway), Jupyter cells, login sessions. Ask once if genuinely unclear.
            """,
        ]
        if let section = contentGuidance(available) { sections.append(section) }
        if let section = waitGuidance(available) { sections.append(section) }
        if let section = startingGuidance(available) { sections.append(section) }
        sections.append(authorityGuidance(authority, available, waitCeiling))
        return sections
    }

    private static func contentGuidance(_ available: Set<String>) -> String? {
        let metadata = [
            "get_pane_info", "get_server_info", "get_session_info", "get_window_info",
            "list_panes", "list_sessions", "list_windows",
        ].filter(available.contains)
        let content = [
            "capture_pane", "capture_since", "search_panes", "snapshot_pane",
        ].filter(available.contains)
        guard !metadata.isEmpty || !content.isEmpty else { return nil }

        var sentences = ["METADATA vs CONTENT:"]
        if !metadata.isEmpty {
            sentences.append(
                "\(names(metadata)) read what tmux objects are; they do not search text."
            )
        }
        if !content.isEmpty {
            sentences.append("\(names(content)) read printed pane content.")
        }
        if available.contains("capture_since") {
            sentences.append(
                "Carry capture_since's opaque cursor across turns; linesMissed or restarted means continuity was reset."
            )
        }
        if available.contains("capture_pane") {
            sentences.append("Use capture_pane start/end for bounded history without pane modes.")
        }
        if available.contains("search_panes") {
            sentences.append("Use search_panes to discover matching scrollback.")
        }
        if available.contains("snapshot_pane") {
            sentences.append(
                "snapshot_pane returns metadata and bounded content in one MCP response, not one atomic read."
            )
        }
        if available.contains("get_tmux_variables") {
            sentences.append(
                "Pane modes are human-owned: read pane_in_mode or pane_mode, report it, and do not enter or cancel it."
            )
        }
        return sentences.joined(separator: " ")
    }

    private static func waitGuidance(_ available: Set<String>) -> String? {
        var lines: [String] = []
        if available.contains("run_shell_command") {
            lines.append(
                "- run_shell_command: a command you wrote for one trusted POSIX shell; returns its exit status."
            )
        }
        if available.contains("wait_for_text") {
            lines.append("- wait_for_text: output you did not author; bound the wait.")
        }
        if available.contains("wait_for_channel") {
            lines.append("- wait_for_channel: when the shell composition must be your own.")
        }
        guard !lines.isEmpty else { return nil }
        if available.contains("send_keys"), available.contains("capture_pane") {
            lines.append("Never loop send_keys + capture_pane; it cannot prove completion.")
        }
        if available.contains("send_keys") {
            lines.append(
                "Pane input checks are observational; resolvedPaneIds reports configured synchronized membership, not delivery."
            )
        }
        if available.contains("paste_text") {
            lines.append("paste_text keeps its text and optional Enter target-only.")
        }
        return (["WAIT, DON'T POLL. Cheapest applicable tool first:"] + lines)
            .joined(separator: "\n")
    }

    private static func startingGuidance(_ available: Set<String>) -> String? {
        var sentences: [String] = []
        if available.contains("get_server_info") {
            sentences.append("START WITH get_server_info when server identity matters.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func authorityGuidance(
        _ authority: ToolAuthority,
        _ available: Set<String>,
        _ waitCeiling: Duration
    ) -> String {
        var sentences: [String] = []
        if available.isEmpty {
            sentences.append("Exact tool selection: none; every tool is hidden and refused.")
        } else {
            sentences.append(
                "Frozen tools: \(names(available)); every other tool is hidden and refused."
            )
        }
        let waits: Set<String> = [
            "run_shell_command", "wait_for_text", "wait_for_channel",
        ]
        if !available.isDisjoint(with: waits) {
            sentences.append("Waits clamp to \(waitCeiling.secondsText)s and report the limit.")
        }
        sentences.append(
            "No attach or choose-*; they need a terminal. Persistent hooks belong in tmux config."
        )
        return sentences.joined(separator: " ")
    }

    private static func names<S: Sequence>(_ operations: S) -> String
    where S.Element == String {
        operations.sorted().joined(separator: ", ")
    }

    private static func joined(_ sections: [String]) -> String {
        sections.joined(separator: "\n\n")
    }
}
