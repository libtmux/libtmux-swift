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

        // The caller's own pane is the one fact no tool call can re-derive: it
        // is about this process, not about tmux.
        if let pane = caller?.paneID {
            sections.append(
                """
                You run inside tmux pane \(pane). Kill tools refuse it without \
                confirm_self; list_panes marks it isCaller.
                """
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
            tmux through libtmux for Swift. Server > Session > Window > Pane. \
            Target panes by id (%1): ids survive layout changes, indexes do not.
            """,

            """
            TRIGGERS: tmux panes, windows, sessions; 'this terminal', 'send keys', \
            'scrollback', 'copy mode'. Ids %1 @1 $1 are unambiguous.
            NOT FOR: browser tabs, editor splits (VS Code, Neovim), GUI windows \
            (i3, sway), Jupyter cells, login sessions. Ask once if genuinely unclear.
            """,

            """
            METADATA vs CONTENT: list_* and filters read what a pane *is* — command, \
            path, size. search_panes and capture_pane read what it has *printed*. \
            Asking a listing about text finds nothing and looks like an empty server.
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
            Never loop send_keys + capture_pane: it cannot tell slow from finished.
            """,

            """
            START WITH describe_server (tmux version, wait ceiling, which pane is \
            yours) and describe_filters (the vocabulary a `filter` may name).
            ONE CALL, NOT FOUR: snapshot reads the whole hierarchy consistently; \
            apply_workspace builds a session from one plan; run_commands batches and \
            says which step failed. Pass `fields` when one field answers the question.
            """,

            """
            Tier: \(tier.rawValue) — tools above it are hidden and refused \
            (LIBTMUX_SAFETY). Waits clamp to \(Int(waitCeiling.components.seconds))s \
            and report what was enforced. No attach, prompts or choose-*: they wait \
            for a terminal a tool call has not got, and run_command refuses them by \
            name. Hooks outlive this process, so they belong in your tmux config.
            """,
        ]
    }

    private static func joined(_ sections: [String]) -> String {
        sections.joined(separator: "\n\n")
    }
}
