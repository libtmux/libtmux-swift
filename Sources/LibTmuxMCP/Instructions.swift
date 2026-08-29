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
        tier: SafetyTier,
        waitCeiling: Duration,
        caller: CallerIdentity?
    ) -> String {
        var sections = required(tier: tier, waitCeiling: waitCeiling)

        // This belongs to the caller process, not to the server hierarchy.
        if let pane = caller?.paneID {
            sections.insert(
                """
                You run inside tmux pane \(pane). Kill tools refuse it without \
                confirm_self; list_panes marks it isCaller.
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
    static func required(tier: SafetyTier, waitCeiling: Duration) -> [String] {
        [
            """
            tmux via libtmux for Swift. Server > Session > Window > Pane. \
            Listings return process-local refs; re-list after MCP restart. \
            list_windows returns exact linkRef occurrences.
            """,

            """
            TRIGGERS: tmux panes, windows, sessions; 'this terminal', 'send keys', \
            'scrollback', 'copy mode'. Use listing refs for follow-ups and linkRef \
            when a window has several links.
            NOT FOR: browser tabs, editor splits (VS Code, Neovim), GUI windows \
            (i3, sway), Jupyter cells, login sessions. Ask once if genuinely unclear.
            """,

            """
            METADATA vs CONTENT: list_* and filters read what a pane *is* — command, \
            path, size. search_panes and capture_pane read what it has *printed*. \
            Listings do not search text. Across turns use capture_since for only the \
            difference; capture_pane re-sends the screen.
            """,

            """
            WAIT, DON'T POLL. Cheapest first:
            - run_shell: a command you wrote. Signals completion through a tmux \
            channel; returns exit status.
            - watch_format: a question about state (#{pane_current_command}, \
            #{pane_dead}). Reads no scrollback.
            - wait_for_output: output you did NOT author. Event-driven. Always pass \
            `stops` for failure markers.
            - wait_for_channel: when the shell composition must be your own.
            Never loop send_keys + capture_pane; it cannot tell slow from finished.
            """,

            """
            START WITH describe_server (tmux version, wait ceiling, which pane is \
            yours) and describe_filters (the vocabulary a `filter` may name).
            ONE CALL: snapshot reads the hierarchy and detects daemon replacement; \
            apply_workspace builds one plan. Pass `fields` for one-field questions.
            """,

            """
            Tier: \(tier.rawValue) — tools above it are hidden and refused \
            (LIBTMUX_SAFETY). Waits clamp to \(waitCeiling.secondsText)s \
            and report the limit. Raw run_command(s) are destructive-tier escape \
            hatches requiring confirm_unsafe, a current server ref, and a deadline. \
            No attach, prompts or choose-*; they need a terminal. Persistent hooks \
            belong in tmux config.
            """,
        ]
    }

    private static func joined(_ sections: [String]) -> String {
        sections.joined(separator: "\n\n")
    }
}
