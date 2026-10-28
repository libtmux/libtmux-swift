import Foundation

/// tmux's command table, and how tmux resolves a name against it.
///
/// A raw batch is read before it is sent, and what it names has to be what
/// tmux will run. tmux accepts a command's name, its alias, or any unique
/// prefix of a name, so `break-p` and `br` run `break-pane`. A guard that only
/// knew the spelled-out names would let the abbreviation through.
enum TmuxCommandTable {
    /// A command, the alias tmux gives it, and the first release that has it.
    /// Empty `since` means every supported release.
    struct Entry: Sendable {
        let name: String
        let alias: String?
        let since: TmuxVersion?
    }

    /// The commands of tmux, in the order tmux searches them. The order
    /// matters: an alias match wins over a prefix match found earlier, and an
    /// exact name match ends the search. `list-commands` prints this order, and
    /// a test holds the table to it on every release it runs against.
    static let entries: [Entry] = rows.map { name, alias, since in
        Entry(name: name, alias: alias, since: since.map(release))
    }

    private static func release(_ spelling: String) -> TmuxVersion {
        guard let version = TmuxVersion(parsing: spelling) else {
            preconditionFailure("unreadable tmux version \(spelling)")
        }
        return version
    }

    /// The spellings tmux expands before it looks a name up, from its default
    /// `command-alias` option. A `command-alias` a caller sets is the caller's
    /// own and is not read.
    static let defaultAliases: [String: String] = [
        "split-pane": "split-window",
        "splitp": "split-window",
    ]

    /// The command `word` names on `version`, as tmux resolves it, or `nil`
    /// when tmux would reject it as unknown or ambiguous.
    static func resolve(_ word: String, on version: TmuxVersion) -> String? {
        if let expanded = defaultAliases[word] { return expanded }
        var found: Entry?
        var ambiguous = false
        for entry in entries {
            if let since = entry.since, version < since { continue }
            if entry.alias == word {
                ambiguous = false
                found = entry
                break
            }
            guard entry.name.utf8.starts(with: word.utf8) else { continue }
            if found != nil { ambiguous = true }
            found = entry
            if entry.name == word { break }
        }
        return ambiguous ? nil : found?.name
    }

    private static let rows: [(String, String?, String?)] = [
        ("attach-session", "attach", nil),
        ("bind-key", "bind", nil),
        ("break-pane", "breakp", nil),
        ("capture-pane", "capturep", nil),
        ("choose-buffer", nil, nil),
        ("choose-client", nil, nil),
        ("choose-tree", nil, nil),
        ("clear-history", "clearhist", nil),
        ("clear-prompt-history", "clearphist", nil),
        ("clock-mode", nil, nil),
        ("command-prompt", nil, nil),
        ("confirm-before", "confirm", nil),
        ("copy-mode", nil, nil),
        ("customize-mode", nil, nil),
        ("delete-buffer", "deleteb", nil),
        ("detach-client", "detach", nil),
        ("display-menu", "menu", nil),
        ("display-message", "display", nil),
        ("display-popup", "popup", nil),
        ("display-panes", "displayp", nil),
        ("find-window", "findw", nil),
        ("has-session", "has", nil),
        ("if-shell", "if", nil),
        ("join-pane", "joinp", nil),
        ("kill-pane", "killp", nil),
        ("kill-server", nil, nil),
        ("kill-session", nil, nil),
        ("kill-window", "killw", nil),
        ("last-pane", "lastp", nil),
        ("last-window", "last", nil),
        ("link-window", "linkw", nil),
        ("list-buffers", "lsb", nil),
        ("list-clients", "lsc", nil),
        ("list-commands", "lscm", nil),
        ("list-keys", "lsk", nil),
        ("list-panes", "lsp", nil),
        ("list-sessions", "ls", nil),
        ("list-windows", "lsw", nil),
        ("load-buffer", "loadb", nil),
        ("lock-client", "lockc", nil),
        ("lock-server", "lock", nil),
        ("lock-session", "locks", nil),
        ("move-pane", "movep", nil),
        ("move-window", "movew", nil),
        ("new-pane", "newp", "next-3.7"),
        ("new-session", "new", nil),
        ("new-window", "neww", nil),
        ("next-layout", "nextl", nil),
        ("next-window", "next", nil),
        ("paste-buffer", "pasteb", nil),
        ("pipe-pane", "pipep", nil),
        ("previous-layout", "prevl", nil),
        ("previous-window", "prev", nil),
        ("refresh-client", "refresh", nil),
        ("rename-session", "rename", nil),
        ("rename-window", "renamew", nil),
        ("resize-pane", "resizep", nil),
        ("resize-window", "resizew", nil),
        ("respawn-pane", "respawnp", nil),
        ("respawn-window", "respawnw", nil),
        ("rotate-window", "rotatew", nil),
        ("run-shell", "run", nil),
        ("save-buffer", "saveb", nil),
        ("select-layout", "selectl", nil),
        ("select-pane", "selectp", nil),
        ("select-window", "selectw", nil),
        ("send-keys", "send", nil),
        ("send-prefix", nil, nil),
        ("server-access", nil, nil),
        ("set-buffer", "setb", nil),
        ("set-environment", "setenv", nil),
        ("set-hook", nil, nil),
        ("set-option", "set", nil),
        ("set-window-option", "setw", nil),
        ("show-buffer", "showb", nil),
        ("show-environment", "showenv", nil),
        ("show-hooks", nil, nil),
        ("show-messages", "showmsgs", nil),
        ("show-options", "show", nil),
        ("show-prompt-history", "showphist", nil),
        ("show-window-options", "showw", nil),
        ("source-file", "source", nil),
        ("split-window", "splitw", nil),
        ("start-server", "start", nil),
        ("suspend-client", "suspendc", nil),
        ("swap-pane", "swapp", nil),
        ("swap-window", "swapw", nil),
        ("switch-client", "switchc", nil),
        ("switch-mode", nil, "3.8"),
        ("unbind-key", "unbind", nil),
        ("unlink-window", "unlinkw", nil),
        ("wait-for", "wait", nil),
    ]
}
