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
    static func required(authority: ToolAuthority, waitCeiling: Duration) -> [String] {
        let available = Set(
            TmuxTools.definitions.lazy
                .filter { authority.rejection(for: $0) == nil }
                .map(\.operation)
        )
        var sections = [
            """
            tmux via libtmux for Swift. Server > Session > Window > Pane. \
            Tool refs are process-local; refresh them after MCP restart.
            """,
            """
            TRIGGERS: tmux panes, windows, sessions; 'this terminal', 'send keys', \
            'scrollback', 'copy mode'.
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

    private static func contentGuidance(_ available: Set<ToolOperation>) -> String? {
        let metadata = [
            ToolOperation.listSessions, .listWindows, .listPanes, .snapshot, .readFormat,
        ].filter(available.contains)
        let content = [
            ToolOperation.searchPanes, .capturePane, .captureSince,
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
        if available.contains(.captureSince) {
            sentences.append("Across turns, capture_since returns only the difference.")
        }
        return sentences.joined(separator: " ")
    }

    private static func waitGuidance(_ available: Set<ToolOperation>) -> String? {
        var lines: [String] = []
        if available.contains(.runShell) {
            lines.append("- run_shell: a command you wrote; returns its exit status.")
        }
        if available.contains(.watchFormat) {
            lines.append("- watch_format: a question about state; reads no scrollback.")
        }
        if available.contains(.waitForOutput) {
            lines.append("- wait_for_output: output you did not author; always pass `stops`.")
        }
        if available.contains(.waitForChannel) {
            lines.append("- wait_for_channel: when the shell composition must be your own.")
        }
        guard !lines.isEmpty else { return nil }
        if available.contains(.sendKeys), available.contains(.capturePane) {
            lines.append("Never loop send_keys + capture_pane; it cannot prove completion.")
        }
        return (["WAIT, DON'T POLL. Cheapest applicable tool first:"] + lines)
            .joined(separator: "\n")
    }

    private static func startingGuidance(_ available: Set<ToolOperation>) -> String? {
        var sentences: [String] = []
        let orientation = [ToolOperation.describeServer, .describeFilters]
            .filter(available.contains)
        if !orientation.isEmpty { sentences.append("START WITH \(names(orientation)).") }
        if available.contains(.snapshot) {
            sentences.append("snapshot reads the hierarchy and detects daemon replacement.")
        }
        if available.contains(.applyWorkspace) {
            sentences.append("apply_workspace builds one workspace plan.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func authorityGuidance(
        _ authority: ToolAuthority,
        _ available: Set<ToolOperation>,
        _ waitCeiling: Duration
    ) -> String {
        var sentences: [String] = []
        if authority.enabledTools == nil {
            sentences.append(
                "Tier: \(authority.tier.rawValue); higher-tier tools are hidden and refused."
            )
        } else if available.isEmpty {
            sentences.append("Exact tool selection: none; every tool is hidden and refused.")
        } else {
            sentences.append(
                "Exact tools: \(names(available)); every other tool is hidden and refused."
            )
        }
        let waits: Set<ToolOperation> = [
            .runShell, .watchFormat, .waitForOutput, .waitForChannel,
        ]
        if !available.isDisjoint(with: waits) {
            sentences.append("Waits clamp to \(waitCeiling.secondsText)s and report the limit.")
        }
        if available.contains(.runCommand) || available.contains(.runCommands) {
            sentences.append("Raw commands require confirm_unsafe, a server ref, and a deadline.")
        }
        sentences.append(
            "No attach, prompts or choose-*; they need a terminal. Persistent hooks belong in tmux config."
        )
        return sentences.joined(separator: " ")
    }

    private static func names<S: Sequence>(_ operations: S) -> String
    where S.Element == ToolOperation {
        operations.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private static func joined(_ sections: [String]) -> String {
        sections.joined(separator: "\n\n")
    }
}
