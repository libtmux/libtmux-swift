import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// MARK: - Which batch a release can run

@Suite("optional tmux features: command guards")
struct CommandGuardTests {
    private func check(_ release: String, _ arguments: [String]) throws(TmuxError) {
        try TmuxCommandGuard.check(arguments, against: Support.Versions.requireCore(release))
    }

    private func refused(_ release: String, _ arguments: [String]) -> Bool {
        do {
            try check(release, arguments)
            return false
        } catch {
            if case .unsupportedTmuxVersion = error { return true }
            return false
        }
    }

    @Test("exact named-buffer deletion and rename need 3.4")
    func namedBufferEditing() {
        for release in ["3.3a"] {
            #expect(refused(release, ["delete-buffer", "-b", "staged"]))
            #expect(refused(release, ["deleteb", "-bstaged"]))
            #expect(refused(release, ["set-buffer", "-b", "old", "-n", "new"]))
            #expect(refused(release, ["new-session", "-d", ";", "delete-buffer", "-b", "x"]))
            // Naming the buffer that is set, pasted or deleted-after-paste is exact on 3.3a.
            #expect(!refused(release, ["set-buffer", "-b", "staged", "--", "text"]))
            #expect(!refused(release, ["paste-buffer", "-d", "-b", "staged"]))
            #expect(!refused(release, ["delete-buffer"]))
        }
        for release in ["3.4", "3.5", "3.7d", "next-3.9"] {
            #expect(!refused(release, ["delete-buffer", "-b", "staged"]))
            #expect(!refused(release, ["set-buffer", "-b", "old", "-n", "new"]))
        }
    }

    @Test("tmux 3.7 crashes break-pane without a name and refuses '.' and ':' in names")
    func exactThreeSeven() {
        #expect(refused("3.7", ["break-pane", "-d", "-s", "%1"]))
        #expect(!refused("3.7", ["break-pane", "-d", "-s", "%1", "-n", "work"]))
        #expect(refused("3.7", ["break-pane", "-s", "%1", "-n", "a.b"]))
        #expect(refused("3.7", ["new-session", "-d", "-s", "a:b"]))
        #expect(refused("3.7", ["new-window", "-n", "x.y"]))
        #expect(refused("3.7", ["rename-window", "-t", "@1", "x:y"]))
        #expect(refused("3.7", ["rename-session", "a.b"]))
        #expect(!refused("3.7", ["new-session", "-d", "-s", "plain"]))
        for release in ["3.6b", "3.7a", "3.7d", "3.8", "next-3.9", "3.3a"] {
            #expect(
                !refused(release, ["break-pane", "-d", "-s", "%1"]), Comment(rawValue: release))
            #expect(
                !refused(release, ["new-session", "-d", "-s", "a.b"]), Comment(rawValue: release))
        }
    }

    @Test("the exact-release checks follow the strict ranking")
    func exactReleasesUseTheRanking() {
        // next-3.7 and 3.7-rc2 rank below 3.7, 3.7a ranks above it.
        for release in ["next-3.7", "3.7-rc", "3.7-rc2", "3.7a", "3.7d"] {
            #expect(!refused(release, ["break-pane", "-s", "%1"]), Comment(rawValue: release))
        }
        #expect(refused("3.7", ["break-pane", "-s", "%1"]))
        for release in ["next-3.4", "3.4-rc", "3.4-rc2"] {
            #expect(!refused(release, ["split-window", "-p", "30"]), Comment(rawValue: release))
        }
        #expect(refused("3.4", ["split-window", "-p", "30"]))
    }

    @Test("a typed session or window name with '.' or ':' is refused on 3.7 before it is sent")
    func typedNamesOnThreeSeven() async throws {
        let script = VersionScript(daemon: "3.7", executable: "3.7")
        let server = Server(
            endpoint: try Endpoint(
                socketPath: "/tmp/libtmux-swift-test/names-\(UUID().uuidString.prefix(8))/s"),
            tmuxExecutable: "/usr/bin/tmux", transport: script, checkingVersions: true)
        await #expect(throws: TmuxError.self) { _ = try await server.newSession(named: "a.b") }
        await #expect(throws: TmuxError.self) {
            _ = try await server.newSession(named: "ok", windowName: "x:y")
        }
        #expect(await script.ran("new-session") == false)
    }

    @Test("split-window -p is broken on 3.4 only")
    func percentSplit() {
        #expect(refused("3.4", ["split-window", "-p", "30"]))
        #expect(refused("3.4", ["splitw", "-hp30"]))
        #expect(!refused("3.4", ["split-window", "-l", "30%"]))
        for release in ["3.3a", "3.5", "3.7d"] {
            #expect(!refused(release, ["split-window", "-p", "30"]), Comment(rawValue: release))
        }
    }

    @Test("below 3.4 only a layout tmux can parse is sent")
    func layoutsBelowThreeFour() {
        #expect(refused("3.3a", ["select-layout", "-t", "@1", "garbage"]))
        #expect(refused("3.3a", ["select-layout", "0000,80x24,0,0,0"]))
        #expect(!refused("3.3a", ["select-layout", "-t", "@1", "tiled"]))
        #expect(!refused("3.3a", ["select-layout", "-t", "@1", "even-h"]))
        #expect(!refused("3.3a", ["select-layout", "-n"]))
        #expect(!refused("3.4", ["select-layout", "-t", "@1", "garbage"]))
    }

    @Test("a command inside a shell string is the caller's own program")
    func shellStringsAreNotRead() {
        #expect(!refused("3.3a", ["if-shell", "-F", "1", "delete-buffer -b x"]))
        #expect(!refused("3.3a", ["run-shell", "tmux delete-buffer -b x"]))
    }

    @Test("a command is named the way tmux names it: alias, unique prefix, default command-alias")
    func commandsAreResolvedLikeTmux() {
        let nameless = ["-d", "-s", "%1"]
        for spelling in ["break-pane", "breakp", "break-p", "break-", "br"] {
            #expect(refused("3.7", [spelling] + nameless), Comment(rawValue: spelling))
            #expect(!refused("3.7", [spelling] + nameless + ["-n", "ok"]))
        }
        // "b" could be bind-key or break-pane, so tmux rejects it and nothing runs.
        #expect(!refused("3.7", ["b"] + nameless))
        #expect(refused("3.7", ["brea", "-d", "-s", "%1", "-n", "a.b"]))

        for spelling in ["delete-buffer", "deleteb", "delete-b", "dele"] {
            #expect(
                refused("3.3a", [spelling, "-b", "missing"]), Comment(rawValue: spelling))
        }
        for spelling in ["set-buffer", "setb", "set-b"] {
            #expect(refused("3.3a", [spelling, "-n", "renamed"]), Comment(rawValue: spelling))
        }
        // "set" is shared by set-buffer, set-environment, set-hook and set-option.
        #expect(!refused("3.3a", ["set", "-n", "renamed"]))

        for spelling in ["new-window", "neww", "new-w"] {
            #expect(refused("3.7", [spelling, "-n", "a.b"]), Comment(rawValue: spelling))
        }
        for spelling in ["new-session", "new", "new-s"] {
            #expect(refused("3.7", [spelling, "-d", "-s", "a:b"]), Comment(rawValue: spelling))
        }
        for spelling in ["rename-window", "renamew", "rename-w"] {
            #expect(refused("3.7", [spelling, "-t", "@1", "x.y"]), Comment(rawValue: spelling))
        }
        for spelling in ["rename-session", "rename", "rename-s"] {
            #expect(refused("3.7", [spelling, "-t", "$1", "x.y"]), Comment(rawValue: spelling))
        }
        for spelling in ["split-window", "splitw", "split-w", "spl", "split-pane", "splitp"] {
            #expect(refused("3.4", [spelling, "-p", "30"]), Comment(rawValue: spelling))
        }
        for spelling in ["select-layout", "selectl", "select-l"] {
            #expect(
                refused("3.3a", [spelling, "-t", "@1", "not-a-layout"]),
                Comment(rawValue: spelling))
        }
    }

    @Test("a command is read inside a list, whatever separates it")
    func listsAreReadCommandByCommand() {
        let hidden = ["break-p", "-d", "-s", "%1"]
        #expect(refused("3.7", ["new-window", "-d", ";"] + hidden))
        #expect(refused("3.7", ["new-window", "-d;"] + hidden))
        #expect(refused("3.7", hidden + [";", "new-window", "-d"]))
        #expect(refused("3.3a", ["new-window", "-d", ";", "delete-b", "-b", "missing"]))
        #expect(refused("3.3a", ["new-window", "-d", ";", "set-b", "-n", "renamed"]))
        #expect(refused("3.3a", ["new-window", "-d", ";", "select-l", "nonsense"]))
        // An escaped ';' is data, so the second word belongs to the first command.
        #expect(!refused("3.7", ["display-message", #"\;"#, "break-p", "-d", "-s", "%1"]))
    }

    @Test("set-buffer reads its flags from tmux's own table")
    func setBufferFlags() {
        // -a and -w take no value and -t takes one, so each of these renames.
        let renaming: [[String]] = [
            ["-a", "-b", "x", "-n", "y"],
            ["-w", "-n", "y"],
            ["-t", "client", "-n", "y"],
            ["-ab", "x", "-n", "y"],
            ["-abx", "-ny"],
            ["-n", "y", "-b", "x"],
            ["-b", "x", "-n", "y", "data"],
        ]
        for flags in renaming {
            #expect(refused("3.3a", ["set-buffer"] + flags), Comment(rawValue: "\(flags)"))
            #expect(!refused("3.4", ["set-buffer"] + flags), Comment(rawValue: "\(flags)"))
        }
        // These name no rename: the value of -b is "-n", or the data follows a --.
        let plain: [[String]] = [
            ["-b", "-n", "y"],
            ["-a", "-b", "x", "--", "-n"],
            ["-b", "x", "data", "-n"],
            ["-aw", "data"],
        ]
        for flags in plain {
            #expect(!refused("3.3a", ["set-buffer"] + flags), Comment(rawValue: "\(flags)"))
        }
    }

    @Test("refresh-client -l, which asks a client for its clipboard, needs 3.4")
    func clipboardQuery() {
        for spelling in ["refresh-client", "refresh", "refresh-c", "refr"] {
            #expect(refused("3.3a", [spelling, "-t", "client", "-l"]), Comment(rawValue: spelling))
            #expect(refused("3.3a", [spelling, "-lx"]), Comment(rawValue: spelling))
            #expect(refused("3.3a", [spelling, "-cl"]), Comment(rawValue: spelling))
            #expect(!refused("3.4", [spelling, "-t", "client", "-l"]), Comment(rawValue: spelling))
        }
        #expect(refused("3.3a", ["new-window", "-d", ";", "refr", "-l"]))
        #expect(refused("3.3a", ["new-window", "-d;", "refresh", "-l"]))
        // -t takes "-l" as its value, and -B is a different request.
        #expect(!refused("3.3a", ["refresh-client", "-t", "-l"]))
        #expect(!refused("3.3a", ["refresh-client", "-B", "name::#{pane_id}"]))
        #expect(!refused("3.3a", ["refresh-client", "-C", "80x24"]))
    }

    @Test("a repeated flag keeps the last value, as tmux does")
    func repeatedFlags() {
        #expect(refused("3.7", ["break-pane", "-s", "%1", "-n", "ok", "-n", "a.b"]))
        #expect(!refused("3.7", ["break-pane", "-s", "%1", "-n", "a.b", "-n", "ok"]))
    }

    @Test("arguments split the way tmux's args_parse splits them")
    func argumentParsing() {
        let parsed = ParsedArguments(
            ["-ab", "x", "-ny", "-w", "--", "-n", "data"], template: "ab:t:n:w")
        #expect(parsed.value(of: "a") == "")
        #expect(parsed.value(of: "b") == "x")
        #expect(parsed.value(of: "n") == "y")
        #expect(parsed.has("w"))
        #expect(!parsed.has("t"))
        #expect(parsed.operands == ["-n", "data"])
        // Flags stop at the first operand, so what follows is not a flag.
        let stopped = ParsedArguments(["data", "-n", "y"], template: "ab:t:n:w")
        #expect(!stopped.has("n"))
        #expect(stopped.operands == ["data", "-n", "y"])
        // A value flag with nothing after it reads an empty value.
        #expect(ParsedArguments(["-n"], template: "n:").value(of: "n") == "")
        // A lone dash is an operand.
        #expect(ParsedArguments(["-"], template: "n:").operands == ["-"])
    }

    @Test("a command name resolves like cmd_find: alias, exact name, unique prefix")
    func tableResolution() throws {
        let release = try #require(TmuxVersion(parsing: "3.7"))
        #expect(TmuxCommandTable.resolve("br", on: release) == "break-pane")
        #expect(TmuxCommandTable.resolve("breakp", on: release) == "break-pane")
        #expect(TmuxCommandTable.resolve("break-pane", on: release) == "break-pane")
        // The alias `new` is exact, though `new-*` names share the prefix.
        #expect(TmuxCommandTable.resolve("new", on: release) == "new-session")
        #expect(TmuxCommandTable.resolve("new-", on: release) == nil)
        #expect(TmuxCommandTable.resolve("b", on: release) == nil)
        #expect(TmuxCommandTable.resolve("", on: release) == nil)
        #expect(TmuxCommandTable.resolve("nosuch", on: release) == nil)
        #expect(TmuxCommandTable.resolve("splitp", on: release) == "split-window")
        // A command a release does not have is not part of its prefixes.
        let older = try #require(TmuxVersion(parsing: "3.6b"))
        #expect(TmuxCommandTable.resolve("new-p", on: older) == nil)
        #expect(TmuxCommandTable.resolve("new-p", on: release) == "new-pane")
    }

    /// Whether a send is refused for its release. A session that is not attached
    /// waits for an attach that never comes, so a send that is not refused is
    /// cut off instead of holding the run open.
    private func sendIsRefused(_ control: ControlSession, _ command: TmuxCommand) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await control.send(command)
                    return false
                } catch TmuxError.unsupportedTmuxVersion {
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test("a send over a control session is read before anything is written")
    func controlSessionSendIsGuarded() async throws {
        let written = WrittenBytes()
        let control = ControlSession(
            write: { await written.append($0) },
            checked: try Support.Versions.requireCore("3.7"))
        for name in ["break-pane", "break-p", "br"] {
            let command = TmuxCommand(name, ["-d", "-s", "%1"])
            #expect(await sendIsRefused(control, command), Comment(rawValue: name))
        }
        let listed = TmuxCommand("new-window", ["-d", ";", "br", "-d", "-s", "%1"])
        #expect(await sendIsRefused(control, listed))
        #expect(await written.count == 0)
    }
}

private actor WrittenBytes {
    private(set) var count = 0
    func append(_ bytes: [UInt8]) { count += bytes.count }
}

// MARK: - Against the lane's tmux

@Suite("optional tmux features: against the lane's tmux", .timeLimit(.minutes(5)))
struct FeatureLaneTests {
    @Test(
        "control attachment is refused below 3.7 before any client attaches",
        .enabled(if: laneIsSupported && !laneSupportsControl, "needs 3.3a to 3.6")
    )
    func controlRefusedBelowThreeSeven() async throws {
        try await withTmuxServer { server in
            await #expect(throws: TmuxError.self) {
                try await server.connected(attachingTo: "bootstrap") { _, _ in 0 }
            }
            await #expect(throws: TmuxError.self) {
                try await server.using(.connected(to: "bootstrap")) { _ in 0 }
            }
            let clients = try await server.clients()
            #expect(clients.allSatisfy { !$0.isControlMode })
            // The same server still serves subprocess work.
            let sessions = try await server.sessions()
            #expect(sessions.map(\.name) == ["bootstrap"])
        }
    }

    @Test(
        "control attachment works from 3.7",
        .enabled(if: laneSupportsControl, "needs 3.7 or newer")
    )
    func controlAllowedFromThreeSeven() async throws {
        try await withTmuxServer { server in
            let names = try await server.connected(attachingTo: "bootstrap") { server, _ in
                try await server.sessions().map(\.name)
            }
            #expect(names == ["bootstrap"])
        }
    }

    @Test(
        "waiting for output polls below 3.7 and attaches no control client",
        .enabled(if: laneIsSupported && !laneSupportsControl, "needs 3.3a to 3.6")
    )
    func waitPollsBelowThreeSeven() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("sleep 1; echo polled-marker-$((20+22))", in: pane)
            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("polled-marker-42")],
                timeout: .seconds(20))
            #expect(result.outcome == .matched)
            #expect(try await server.clients().allSatisfy { !$0.isControlMode })
        }
    }

    @Test(
        "named buffers cannot be deleted exactly below 3.4, and nothing is deleted",
        .enabled(if: laneIsSupported && !laneSupportsNamedBufferEditing, "needs 3.3a")
    )
    func bufferDeletionRefusedBelowThreeFour() async throws {
        try await withTmuxServer { server in
            try await server.setBuffer("keep", named: "keep-me")
            try await server.setBuffer("top", named: "newest")
            await #expect(throws: TmuxError.self) {
                try await server.deleteBuffer(named: "keep-me")
            }
            await #expect(throws: TmuxError.self) {
                try await server.deleteBuffer(named: "does-not-exist")
            }
            #expect(Set(try await server.buffers().map(\.name)) == ["keep-me", "newest"])
            #expect(try await server.buffer(named: "keep-me") == "keep")
        }
    }

    @Test(
        "named buffers are deleted exactly from 3.4",
        .enabled(if: laneSupportsNamedBufferEditing, "needs 3.4 or newer")
    )
    func bufferDeletionFromThreeFour() async throws {
        try await withTmuxServer { server in
            try await server.setBuffer("keep", named: "keep-me")
            try await server.setBuffer("top", named: "newest")
            try await server.deleteBuffer(named: "keep-me")
            #expect(try await server.buffers().map(\.name) == ["newest"])
        }
    }

    @Test(
        "a pane alone in its window breaks out and is read back on every supported release",
        .enabled(if: laneIsSupported, "needs a supported tmux")
    )
    func singlePaneBreakIsReread() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            let pane = try #require(try await server.panes().first { $0.windowID == window.id })
            let link = try #require(try await server.windowLinks().first)
            let appearance = try await server.breakPane(pane, from: link, named: "alone")
            #expect(appearance.window.id == window.id)
            #expect(appearance.window.paneCount == 1)
            #expect(appearance.window.name == "alone")
        }
    }

    @Test(
        "a layout tmux 3.3a would crash on is refused before it is sent",
        .enabled(if: laneIsSupported && !laneAtLeast(3, 4), "needs 3.3a")
    )
    func invalidLayoutNeverReachesThreeThreeA() async throws {
        try await withTmuxServer { server in
            let identity = try await server.incarnation()
            await #expect(throws: TmuxError.self) {
                _ = try await server.run(
                    TmuxCommand("select-layout", ["-t", "bootstrap", "not-a-layout"]))
            }
            // The daemon is still the one that was there.
            #expect(try await server.incarnation() == identity)
        }
    }
}

// MARK: - tmux's own tables

@Suite("optional tmux features: tmux's command table", .timeLimit(.minutes(5)))
struct CommandTableLaneTests {
    private func lane() throws -> TmuxVersion { try #require(tmuxLaneRelease()) }

    private func socketPath(_ server: Server) throws -> String {
        guard case let .socketPath(path) = server.endpoint else {
            throw TmuxFixtureFailure("the fixture serves a socket path")
        }
        return path
    }

    @Test(
        "the table lists the commands list-commands lists, with their aliases, in order",
        .enabled(if: laneIsSupported, "needs a supported tmux"))
    func tableMatchesListCommands() async throws {
        let release = try lane()
        try await withTmuxServer { server in
            let reply = try await server.run(
                TmuxCommand("list-commands", ["-F", "#{command_list_name} #{command_list_alias}"]))
            let listed = reply.text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { line -> String in
                    let parts = line.split(separator: " ", omittingEmptySubsequences: false)
                    return "\(parts[0]) \(parts.count > 1 ? String(parts[1]) : "")"
                }
            let table = TmuxCommandTable.entries
                .filter { $0.since.map { release >= $0 } ?? true }
                .map { "\($0.name) \($0.alias ?? "")" }
            #expect(table == listed)
        }
    }

    @Test(
        "every spelling resolves to the command tmux runs, or to nothing where tmux rejects it",
        .enabled(if: laneIsSupported, "needs a supported tmux"))
    func resolutionMatchesTmux() async throws {
        let release = try lane()
        try await withTmuxServer { server in
            let path = try socketPath(server)
            var words = Set(TmuxCommandTable.defaultAliases.keys)
            for entry in TmuxCommandTable.entries {
                if let since = entry.since, release < since { continue }
                if let alias = entry.alias { words.insert(alias) }
                for length in 1...entry.name.count {
                    words.insert(String(entry.name.prefix(length)))
                }
            }
            words.formUnion(["nosuch", "new-", "set", "b", "s"])
            var disagreements: [String] = []
            for word in words.sorted() {
                // An invalid flag fails the parse of the command it follows, so
                // nothing runs; tmux names the command it resolved in the error.
                let result = try #require(
                    spawnCapturing(tmuxExecutablePath(), ["-S", path, word, "-!"]))
                let resolved: String? =
                    result.error.hasPrefix("command ")
                    ? result.error.dropFirst("command ".count).prefix { $0 != ":" }
                        .description
                    : nil
                if resolved != TmuxCommandTable.resolve(word, on: release) {
                    disagreements.append("\(word): tmux \(resolved ?? "rejects")")
                }
            }
            #expect(disagreements.isEmpty, Comment(rawValue: disagreements.joined(separator: "; ")))
        }
    }

    @Test(
        "the flags the guard reads agree with each command's usage in tmux",
        .enabled(if: laneIsSupported, "needs a supported tmux"))
    func flagTemplatesMatchUsage() async throws {
        try await withTmuxServer { server in
            let reply = try await server.run(
                TmuxCommand("list-commands", ["-F", "#{command_list_name}\t#{command_list_usage}"]))
            var checked = 0
            for line in reply.text.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let template = TmuxCommandGuard.templates[String(parts[0])]
                else { continue }
                let valued = ParsedArguments.valuedFlags(in: template)
                var usage = Substring(parts[1])
                var takesValue: Set<Character> = []
                var takesNone: Set<Character> = []
                while let open = usage.range(of: "[-") {
                    usage = usage[open.upperBound...]
                    guard let close = usage.firstIndex(of: "]") else { break }
                    let body = usage[..<close]
                    if body.contains(" ") {
                        takesValue.insert(try #require(body.first))
                    } else {
                        takesNone.formUnion(body)
                    }
                    usage = usage[close...]
                }
                // Some usage lines list a flag in both places; the value wins.
                for flag in takesValue {
                    #expect(valued.contains(flag), Comment(rawValue: "\(parts[0]) -\(flag)"))
                }
                for flag in takesNone.subtracting(takesValue) {
                    #expect(!valued.contains(flag), Comment(rawValue: "\(parts[0]) -\(flag)"))
                    #expect(template.contains(flag), Comment(rawValue: "\(parts[0]) -\(flag)"))
                }
                checked += 1
            }
            #expect(checked == TmuxCommandGuard.templates.count)
        }
    }
}

private struct TmuxFixtureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Raw paths against exact releases

@Suite("optional tmux features: raw paths on real tmux", .timeLimit(.minutes(5)))
struct RawPathLaneTests {
    private func expectRefused(
        _ operation: () async throws -> Void, _ spelling: String
    ) async {
        do {
            try await operation()
            Issue.record("\(spelling) was sent")
        } catch TmuxError.unsupportedTmuxVersion {
        } catch {
            Issue.record("\(spelling) failed some other way: \(error)")
        }
    }

    /// A window of two panes, so that breaking one out is possible.
    private func twoPaneWindow(_ server: Server) async throws -> (first: Pane, second: Pane) {
        let first = try #require(try await server.panes().first)
        _ = try await server.run(
            TmuxCommand("split-window", ["-d", "-t", first.id.rawValue, "exec sleep 600"]))
        let second = try #require(try await server.panes().first { $0.id != first.id })
        return (first, second)
    }

    /// Whether the daemon is the one that was there and nothing was broken out.
    private func untouched(
        _ server: Server, incarnation: ServerIncarnation, windows: Int
    ) async throws -> Bool {
        let current = try await server.incarnation()
        let count = try await server.windows().count
        return current == incarnation && count == windows
    }

    private static let spellings = ["break-pane", "breakp", "break-p", "br"]

    @Test(
        "a nameless break-pane never reaches tmux 3.7, however it is spelled or listed",
        .enabled(if: laneIsExactly(3, 7), "needs exactly tmux 3.7"))
    func processPathRefusesOnThreeSeven() async throws {
        try await withTmuxServer { server in
            let (_, second) = try await twoPaneWindow(server)
            let incarnation = try await server.incarnation()
            let windows = try await server.windows().count
            for spelling in Self.spellings {
                let arguments = ["-d", "-s", second.id.rawValue]
                await expectRefused(
                    { _ = try await server.run(TmuxCommand(spelling, arguments)) }, spelling)
                await expectRefused(
                    {
                        _ = try await server.run(
                            TmuxCommandList([
                                TmuxCommand("new-window", ["-d"]), TmuxCommand(spelling, arguments),
                            ]))
                    }, "new-window ; \(spelling)")
            }
            await expectRefused(
                {
                    _ = try await server.run(
                        TmuxCommand(
                            "new-window", ["-d", ";", "br", "-d", "-s", second.id.rawValue]))
                }, "a trailing separator")
            #expect(try await untouched(server, incarnation: incarnation, windows: windows))
        }
    }

    @Test(
        "a nameless break-pane never reaches tmux 3.7 over a connection",
        .enabled(if: laneIsExactly(3, 7), "needs exactly tmux 3.7"))
    func connectionPathRefusesOnThreeSeven() async throws {
        try await withTmuxServer { server in
            let (_, second) = try await twoPaneWindow(server)
            let incarnation = try await server.incarnation()
            let windows = try await server.windows().count
            let arguments = ["-d", "-s", second.id.rawValue]
            try await server.connected(attachingTo: "bootstrap") { connected, control in
                for spelling in Self.spellings {
                    // A server handed out by a connection.
                    await self.expectRefused(
                        { _ = try await connected.run(TmuxCommand(spelling, arguments)) },
                        "connected \(spelling)")
                    await self.expectRefused(
                        {
                            _ = try await connected.run(
                                TmuxCommandList([
                                    TmuxCommand("new-window", ["-d"]),
                                    TmuxCommand(spelling, arguments),
                                ]))
                        }, "connected list \(spelling)")
                    // The connection itself, which a caller can reach directly.
                    await self.expectRefused(
                        { _ = try await control.send(TmuxCommand(spelling, arguments)) },
                        "ControlSession.send \(spelling)")
                }
            }
            #expect(try await untouched(server, incarnation: incarnation, windows: windows))
        }
    }

    @Test(
        "a nameless break-pane never reaches tmux 3.7 through a guarded request",
        .enabled(if: laneIsExactly(3, 7), "needs exactly tmux 3.7"))
    func guardedRequestRefusesOnThreeSeven() async throws {
        try await withTmuxServer { server in
            let (_, second) = try await twoPaneWindow(server)
            let incarnation = try await server.incarnation()
            let windows = try await server.windows().count
            let command = TmuxCommand("break-pane", ["-d", "-s", second.id.rawValue])
            await expectRefused(
                { _ = try await server.runGuarded(command, by: [.pane(second)]) },
                "runGuarded")
            try await server.connected(attachingTo: "bootstrap") { connected, _ in
                await self.expectRefused(
                    { _ = try await connected.runGuarded(command, by: [.pane(second)]) },
                    "connected runGuarded")
            }
            #expect(try await untouched(server, incarnation: incarnation, windows: windows))
        }
    }

    @Test(
        "a name with a separator is refused on tmux 3.7 in every spelling",
        .enabled(if: laneIsExactly(3, 7), "needs exactly tmux 3.7"))
    func separatorsAreRefusedOnThreeSeven() async throws {
        try await withTmuxServer { server in
            let incarnation = try await server.incarnation()
            let windows = try await server.windows().count
            for spelling in ["new-window", "neww", "new-w"] {
                await expectRefused(
                    { _ = try await server.run(TmuxCommand(spelling, ["-d", "-n", "a.b"])) },
                    spelling)
            }
            #expect(try await untouched(server, incarnation: incarnation, windows: windows))
        }
    }

    @Test(
        "refresh-client -l never reaches a tmux 3.3a server with a client attached",
        .enabled(if: laneIsSupported && !laneAtLeast(3, 4), "needs tmux 3.3a")
    )
    func clipboardQueryIsRefusedOnThreeThreeA() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(path) = server.endpoint else {
                Issue.record("the fixture serves a socket path")
                return
            }
            let client = try PtyClient(socketPath: path, session: "bootstrap")
            defer { client.close() }
            let attached = try await waitUntil(within: .seconds(15)) {
                try await server.clients().contains { !$0.isControlMode }
            }
            try #require(attached)
            let name = try #require(try await server.clients().first { !$0.isControlMode }).name
            let incarnation = try await server.incarnation()
            for spelling in ["refresh-client", "refresh", "refr"] {
                await expectRefused(
                    { _ = try await server.run(TmuxCommand(spelling, ["-t", name, "-l"])) },
                    spelling)
            }
            await expectRefused(
                {
                    _ = try await server.run(
                        TmuxCommandList([
                            TmuxCommand("new-window", ["-d"]),
                            TmuxCommand("refresh", ["-t", name, "-l"]),
                        ]))
                }, "new-window ; refresh")
            #expect(try await server.incarnation() == incarnation)
            #expect(try await server.sessions().map(\.name) == ["bootstrap"])
        }
    }

    @Test(
        "abbreviated buffer commands never reach tmux 3.3a, and no buffer is touched",
        .enabled(if: laneIsSupported && !laneAtLeast(3, 4), "needs tmux 3.3a"))
    func bufferCommandsAreRefusedOnThreeThreeA() async throws {
        try await withTmuxServer { server in
            try await server.setBuffer("keep", named: "keep-me")
            try await server.setBuffer("top", named: "newest")
            let windows = try await server.windows().count
            let raw: [[String]] = [
                ["delete-b", "-b", "missing"],
                ["deleteb", "-b", "missing"],
                ["delete-buffer", "-b", "missing"],
                ["set-b", "-n", "renamed"],
                ["set-buffer", "-a", "-b", "missing", "-n", "renamed"],
                ["set-buffer", "-w", "-n", "renamed"],
                ["set-buffer", "-t", "client", "-n", "renamed"],
                ["setb", "-ab", "missing", "-n", "renamed"],
            ]
            for words in raw {
                await expectRefused(
                    { _ = try await server.run(TmuxCommand(words[0], Array(words.dropFirst()))) },
                    words.joined(separator: " "))
                await expectRefused(
                    {
                        _ = try await server.run(
                            TmuxCommandList([
                                TmuxCommand("new-window", ["-d"]),
                                TmuxCommand(words[0], Array(words.dropFirst())),
                            ]))
                    }, "new-window ; " + words.joined(separator: " "))
            }
            #expect(Set(try await server.buffers().map(\.name)) == ["keep-me", "newest"])
            #expect(try await server.windows().count == windows)
        }
    }
}

/// A client attached through a pseudo-terminal, which is what a clipboard
/// query needs: without a client the command only reports that there is none.
private final class PtyClient: @unchecked Sendable {
    private let process = Process()
    private let master: Int32
    private let slave: FileHandle

    init(socketPath: String, session: String) throws {
        let master = Self.openMaster()
        guard master >= 0, let name = Self.slaveName(of: master) else {
            throw TmuxFixtureFailure("no pseudo-terminal")
        }
        self.master = master
        guard let handle = FileHandle(forUpdatingAtPath: name) else {
            throw TmuxFixtureFailure("cannot open the pseudo-terminal")
        }
        slave = handle
        process.executableURL = URL(fileURLWithPath: tmuxExecutablePath())
        process.arguments = ["-S", socketPath, "attach", "-t", session]
        process.environment = ProcessInfo.processInfo.environment.merging(["TERM": "xterm-256color"]
        ) {
            _, new in new
        }
        process.standardInput = handle
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        // The client draws on attach; reading keeps its output from filling up.
        let descriptor = master
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while read(descriptor, &buffer, buffer.count) > 0 {}
        }
    }

    private static func openMaster() -> Int32 {
        #if canImport(Darwin)
            let descriptor = posix_openpt(O_RDWR | O_NOCTTY)
            guard descriptor >= 0, grantpt(descriptor) == 0, unlockpt(descriptor) == 0 else {
                return -1
            }
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            return descriptor
        #else
            let descriptor = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
            var unlock: Int32 = 0
            // Close-on-exec, so the client does not inherit the master of its own terminal.
            // TIOCSPTLCK: allow the slave side to be opened.
            guard descriptor >= 0, ioctl(descriptor, 0x4004_5431, &unlock) == 0 else { return -1 }
            return descriptor
        #endif
    }

    private static func slaveName(of master: Int32) -> String? {
        #if canImport(Darwin)
            return ptsname(master).map { String(cString: $0) }
        #else
            var number: UInt32 = 0
            // TIOCGPTN: the number of the slave, /dev/pts/N.
            guard ioctl(master, 0x8004_5430, &number) == 0 else { return nil }
            return "/dev/pts/\(number)"
        #endif
    }

    func close() {
        // Not waited for: the client is a bystander, and the server it was
        // attached to is killed right after.
        kill(process.processIdentifier, SIGKILL)
        Glibc.close(master)
    }
}
