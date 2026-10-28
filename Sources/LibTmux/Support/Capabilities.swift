import Foundation

extension Support {
    /// What this library can do on each tmux release, and the release defects
    /// it works around: one table that the gates read and the committed
    /// `capabilities.json` is written from.
    ///
    /// A capability is a feature that exists from one release on. A workaround
    /// is a defect in exact releases that the library refuses or repairs. Only
    /// what a gate here reads is listed; an entry makes a claim, so an absent
    /// one makes none: capture, `run-shell` and the other commands this library
    /// sends the same way on every supported release have no entry because no
    /// gate reads them, and it has no `list-keys` API. Kept apart from the MCP
    /// tool catalogue in `LibTmuxMCP`, which describes tools, not releases.
    enum Capabilities {
        /// What the library does where a capability is not available.
        enum Handling: String, Sendable {
            case refuse, fallback, repair
        }

        /// A tmux command, and the flags of it that an entry depends on.
        struct Command: Sendable {
            let command: String
            let flags: [String]

            init(_ command: String, _ flags: String...) {
                self.command = command
                self.flags = flags
            }
        }

        /// A feature that works from `since` on.
        struct Capability: Sendable {
            let id: String
            let name: String
            let summary: String
            /// The first release it works on, spelled as tmux prints it.
            let since: String
            /// Exact releases at or above `since` where it does not work.
            let except: [String]
            let handling: Handling
            /// The error a refusal throws, named as the API reference spells it.
            let error: String?
            let apis: [String]
            let commands: [Command]

            /// ``since`` as a version, for a gate to compare against.
            var minimum: TmuxVersion { Capabilities.version(since) }
        }

        /// A defect in exact releases.
        struct Workaround: Sendable {
            let id: String
            let name: String
            let summary: String
            /// The exact affected releases, spelled as tmux prints them.
            let releases: [String]
            let handling: Handling
            /// The release a refusal names as the one that is safe.
            let fixedIn: String
            let apis: [String]
            let commands: [Command]

            /// Whether `version` is one of the affected releases. A release
            /// spans its own patch letter only: `3.7` covers `3.7` and not
            /// `3.7a`, and a snapshot or candidate of it ranks below it.
            func affects(_ version: TmuxVersion) -> Bool {
                releases.contains { release in
                    let start = Capabilities.version(release)
                    return version >= start && version < start.nextPointRelease
                }
            }

            /// ``fixedIn`` as a version.
            var fixed: TmuxVersion { Capabilities.version(fixedIn) }
        }

        private static let unsupported =
            "TmuxError.unsupportedTmuxVersion(reported:required:operation:)"

        static let capabilities: [Capability] = [
            Capability(
                id: "control-mode",
                name: "Control mode",
                summary: "Attach a library-managed control client and stream events.",
                since: "3.7", except: [], handling: .refuse, error: unsupported,
                apis: [
                    "Server.withControlMode(attachingTo:_:)",
                    "Server.connected(attachingTo:_:)",
                    "Server.using(_:_:)",
                ],
                commands: [Command("attach-session")]),
            Capability(
                id: "buffer-delete-named",
                name: "Named buffer deletion",
                summary: "Delete one paste buffer by name without risking another buffer.",
                since: "3.4", except: [], handling: .refuse, error: unsupported,
                apis: ["Server.deleteBuffer(named:)"],
                commands: [Command("delete-buffer", "-b")]),
            Capability(
                id: "buffer-rename",
                name: "Named buffer rename",
                summary: "Rename one paste buffer without risking another buffer.",
                since: "3.4", except: [], handling: .refuse, error: unsupported,
                apis: ["Server.run(_:)"],
                commands: [Command("set-buffer", "-b", "-n")]),
            Capability(
                id: "clipboard-query",
                name: "Clipboard query",
                summary: "Ask an attached client for its clipboard with refresh-client -l.",
                since: "3.6a", except: [], handling: .refuse, error: unsupported,
                apis: ["Server.run(_:)", "ControlSession.send(_:)"],
                commands: [Command("refresh-client", "-l")]),
            Capability(
                id: "layout-without-checksum",
                name: "Layout string without a checksum",
                summary: "select-layout reports a layout that lacks its checksum as invalid.",
                since: "3.4", except: [], handling: .refuse, error: unsupported,
                apis: ["Server.selectLayout(_:_:)", "Server.run(_:)"],
                commands: [Command("select-layout")]),
            Capability(
                id: "layout-mirrored-main",
                name: "Mirrored main layouts",
                summary: "Apply main-horizontal-mirrored and main-vertical-mirrored.",
                since: "3.5", except: [], handling: .refuse,
                error: "TmuxError.invocationFailed(reason:)",
                apis: ["Server.selectLayout(_:_:)", "Server.validateLayouts(_:)"],
                commands: [Command("select-layout")]),
            Capability(
                id: "layout-json",
                name: "JSON layouts",
                summary: "Apply a layout in the JSON form that tmux reports.",
                since: "3.8", except: [], handling: .refuse,
                error: "TmuxError.invocationFailed(reason:)",
                apis: ["Server.selectLayout(_:_:)", "Server.validateLayouts(_:)"],
                commands: [Command("select-layout")]),
        ]

        static let workarounds: [Workaround] = [
            Workaround(
                id: "break-pane-misnames-windows",
                name: "break-pane names windows wrongly on 3.7",
                summary:
                    "break-pane gives the new window the default name when -n is given and "
                    + "fails when it is not; breakPane passes a name, and a raw command is refused.",
                releases: ["3.7"], handling: .repair, fixedIn: "3.7a",
                apis: ["Server.breakPane(_:from:named:)"],
                commands: [Command("break-pane", "-n")]),
            Workaround(
                id: "split-window-percent-size",
                name: "split-window -p reads -l on 3.4",
                summary: "split-window -p takes its value from -l, so a raw -p is refused.",
                releases: ["3.4"], handling: .refuse, fixedIn: "3.5",
                apis: ["Server.run(_:)"],
                commands: [Command("split-window", "-p")]),
            Workaround(
                id: "name-separators-rejected",
                name: "Names with a colon or period on 3.7",
                summary:
                    "new-session, new-window, rename-session and rename-window reject a name "
                    + "containing ':' or '.', so the library refuses one before it is sent.",
                releases: ["3.7"], handling: .refuse, fixedIn: "3.7a",
                apis: [
                    "Server.newSession(named:startDirectory:windowName:width:height:)",
                    "Server.newWindow(in:named:startDirectory:)",
                    "Server.rename(_:to:)",
                ],
                commands: [
                    Command("new-session", "-n", "-s"), Command("new-window", "-n"),
                    Command("rename-session"), Command("rename-window"),
                ]),
        ]

        static func capability(_ id: String) -> Capability {
            guard let found = capabilities.first(where: { $0.id == id }) else {
                preconditionFailure("no capability \(id)")
            }
            return found
        }

        static func workaround(_ id: String) -> Workaround {
            guard let found = workarounds.first(where: { $0.id == id }) else {
                preconditionFailure("no workaround \(id)")
            }
            return found
        }

        /// A version as the table spells it. A spelling that does not parse is
        /// a defect in the table, found by the first test run.
        static func version(_ spelling: String) -> TmuxVersion {
            guard let version = TmuxVersion(parsing: spelling) else {
                preconditionFailure("unreadable tmux version \(spelling)")
            }
            return version
        }

        // MARK: Manifest

        private struct CommandRecord: Encodable {
            let command: String
            let flags: [String]?
        }

        private struct CapabilityRecord: Encodable {
            let id, name, summary, since: String
            let except: [String]?
            let handling: String
            let error: String?
            let apis: [String]
            let commands: [CommandRecord]
        }

        private struct WorkaroundRecord: Encodable {
            let id, name, summary: String
            let releases: [String]
            let handling: String
            let apis: [String]
            let commands: [CommandRecord]
        }

        private struct Manifest: Encodable {
            struct Floor: Encodable { let minimum: String }
            let schema = "libtmux-capabilities/1"
            let port = "swift"
            let floor = Floor(minimum: "\(TmuxVersion.coreMinimum)")
            let capabilities: [CapabilityRecord]
            let workarounds: [WorkaroundRecord]
        }

        private static func records(_ commands: [Command]) -> [CommandRecord] {
            commands.map {
                CommandRecord(command: $0.command, flags: $0.flags.isEmpty ? nil : $0.flags)
            }
        }

        /// The text of `capabilities.json`: sorted keys, two-space indent and a
        /// trailing newline, so the same table always gives the same bytes.
        static func manifest() throws -> String {
            let manifest = Manifest(
                capabilities: capabilities.map {
                    CapabilityRecord(
                        id: $0.id, name: $0.name, summary: $0.summary, since: $0.since,
                        except: $0.except.isEmpty ? nil : $0.except,
                        handling: $0.handling.rawValue, error: $0.error, apis: $0.apis,
                        commands: records($0.commands))
                },
                workarounds: workarounds.map {
                    WorkaroundRecord(
                        id: $0.id, name: $0.name, summary: $0.summary, releases: $0.releases,
                        handling: $0.handling.rawValue, apis: $0.apis,
                        commands: records($0.commands))
                })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(manifest), as: UTF8.self) + "\n"
        }
    }
}

extension TmuxVersion {
    /// The release after this one's patch letter: `3.7` gives `3.7a`, `3.7a`
    /// gives `3.7b`. A build suffix is dropped, so the result ranks as the
    /// release.
    fileprivate var nextPointRelease: TmuxVersion {
        let next = pointRelease.unicodeScalars.last.flatMap { Unicode.Scalar($0.value + 1) }
        return TmuxVersion(
            major: major, minor: minor,
            pointRelease: String(pointRelease.dropLast()) + (next.map(String.init) ?? "a"))
    }
}
