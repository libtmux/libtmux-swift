import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

/// A live connection serves the same calls a process does, which is what lets a
/// mode be a dispatch strategy rather than a second API.
///
/// It is not invisible, and cannot be: a control connection is a client, and a
/// client is attached to a session. tmux has no way to connect without one —
/// a bare `tmux -C` runs its default command and *creates* a session, which is
/// worse than attaching to a named one. So the connection shows up in what the
/// server reports about itself, and only there.
@Suite("dispatch over a connection", .timeLimit(.minutes(1)))
struct ModeProbeTests {
    @Test("the same query answers the same over either mode")
    func sameQueryAnswersTheSame() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "alpha")
            _ = try await server.newSession(named: "béta ✓")

            let direct = try await server.sessions()
            let connected = try await server.connected(attachingTo: "bootstrap") { server, _ in
                try await server.sessions()
            }

            // Same sessions, same order, same ids — including a name whose
            // non-ASCII bytes have to survive the connection's `LC_ALL=C`.
            #expect(connected.map(\.id) == direct.map(\.id))
            #expect(connected.map(\.name) == direct.map(\.name))
            #expect(direct.contains { $0.name == "béta ✓" })

            // The one field that differs is the one the connection changed, on
            // the one session it attached to.
            let differing = zip(connected, direct).filter { $0 != $1 }.map(\.0.name)
            #expect(differing == ["bootstrap"])
        }
    }

    @Test("a mutation over the connection is the same mutation")
    func mutationsCarryOverTheConnection() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "work")

            let window = try await server.connected(attachingTo: "bootstrap") { server, _ in
                try await server.newWindow(in: session, named: "made-over-the-wire")
            }
            #expect(window.name == "made-over-the-wire")

            // Visible to a plain process afterwards: the connection did the
            // work, not a copy of it.
            let windows = try await server.windows()
            #expect(windows.contains { $0.id == window.id })
        }
    }

    @Test("a rejected command is still a reply, not a thrown error")
    func rejectionKeepsItsShape() async throws {
        try await withTmuxServer { server in
            let reply = try await server.connected(attachingTo: "bootstrap") { server, _ in
                try await server.run(TmuxCommand("has-session", ["-t", "absent"]))
            }
            #expect(!reply.isSuccess)
            #expect(!reply.errorText.isEmpty)
        }
    }

    @Test("concurrent calls over one connection pipeline, and stay attributed")
    func concurrentCallsPipelineOverOneConnection() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "alpha")
            let expected = try await server.sessions().map(\.id)

            // Four different listings at once over a single connection. This is
            // the pipelined batch: no new API, just Swift's own concurrency and
            // a mode that can carry more than one command at a time. If replies
            // were matched by arrival rather than to their command, these would
            // cross and the decode would fail or return another call's rows.
            let result = try await server.connected(attachingTo: "bootstrap") { server, _ in
                async let sessions = server.sessions()
                async let windows = server.windows()
                async let panes = server.panes()
                async let clients = server.clients()
                return try await (sessions, windows, panes, clients)
            }

            #expect(result.0.map(\.id) == expected)
            #expect(!result.1.isEmpty)
            #expect(!result.2.isEmpty)
            // The connection itself is the client.
            #expect(result.3.count == 1)
        }
    }

    @Test("a command list does the same work over either mode")
    func commandListsCarryOverTheConnection() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            var list = TmuxCommandList()
            for index in 0..<4 {
                list = list.then(
                    "new-window",
                    ["-d", "-t", session.id, "-n", "listed\(index)"]
                )
            }

            let before = try await server.windows().count
            let sending = list
            _ = try await server.connected(attachingTo: "bootstrap") { server, _ in
                try await server.run(sending)
            }

            // Every command in the list ran, not just the first: the separators
            // between them have to reach tmux as punctuation, and a connection
            // quotes arguments on the way.
            let names = try await server.windows().map(\.name)
            #expect(try await server.windows().count == before + 4)
            for index in 0..<4 {
                #expect(names.contains("listed\(index)"))
            }
        }
    }

    @Test("a format reads the same field over either mode")
    func formatsCarryOverTheConnection() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)

            let direct = try await server.format("#{pane_tty}", for: pane)
            let connected = try await server.connected(attachingTo: "bootstrap") {
                server,
                _ in
                try await server.format("#{pane_tty}", for: pane)
            }
            #expect(connected == direct)
            #expect(connected?.hasPrefix("/dev/") == true)
        }
    }

    @Test("an argument spanning lines is refused rather than quietly cut short")
    func newlineArgumentIsRefusedOverAConnection() async throws {
        try await withTmuxServer { server in
            // A process takes an argument vector, so a newline inside one is
            // just a byte.
            let direct = try await server.setOption(
                "@spanning",
                to: "one\ntwo",
                scope: .server
            )
            #expect(direct.isSuccess, Comment(rawValue: direct.errorText))

            // A connection takes a command *line*. Nothing encodes such an
            // argument safely: single quotes leave the newline ending the
            // command, and double quotes carry it only by also letting tmux
            // expand any `#` and `$` in the value. So it is refused.
            await #expect(throws: TmuxError.self) {
                try await server.connected(attachingTo: "bootstrap") { server, _ in
                    try await server.setOption(
                        "@spanning",
                        to: "one\ntwo",
                        scope: .server
                    )
                }
            }
        }
    }

    @Test("a file reaches a buffer over a connection that its text could not")
    func loadBufferCarriesWhatACommandLineCannot() async throws {
        try await withTmuxServer { server in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("libtmux-load-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("lines")
            try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)

            try await server.connected(attachingTo: "bootstrap") { server, _ in
                // The text itself spans lines, and a connection sends a command
                // line, so passing it as an argument is refused.
                await #expect(throws: TmuxError.self) {
                    try await server.setBuffer("one\ntwo", named: "spanning")
                }

                // The path does not span lines. tmux reads the file itself, so
                // the buffer holds what an argument could not carry.
                try await server.loadBuffer(from: file.path, named: "spanning")
                #expect(try await server.buffer(named: "spanning") == "one\ntwo")
            }
        }
    }

    @Test("a buffer reads the same over either mode, newline-terminated or not")
    func bufferReadsTheSameOverEitherMode() async throws {
        try await withTmuxServer { server in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("libtmux-shape-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            // Both shapes, because they are what a connection cannot tell
            // apart: it reports output as lines, and `show-buffer` writes bytes
            // followed by a terminator, so a buffer ending in a newline arrives
            // looking like a listing whose last row is empty.
            let terminated = directory.appendingPathComponent("terminated")
            let bare = directory.appendingPathComponent("bare")
            try "one\ntwo\n".write(to: terminated, atomically: true, encoding: .utf8)
            try "one\ntwo".write(to: bare, atomically: true, encoding: .utf8)
            try await server.loadBuffer(from: terminated.path, named: "terminated")
            try await server.loadBuffer(from: bare.path, named: "bare")

            let direct = [
                try await server.buffer(named: "terminated"),
                try await server.buffer(named: "bare"),
            ]
            let connected = try await server.connected(attachingTo: "bootstrap") {
                server,
                _ in
                [
                    try await server.buffer(named: "terminated"),
                    try await server.buffer(named: "bare"),
                ]
            }

            #expect(connected == direct)
            #expect(direct == ["one\ntwo", "one\ntwo"])
        }
    }

    @Test("the same work reads the same whichever mode is passed as a value")
    func usingCarriesTheModeAsData() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "alpha")

            // One call shape, and the mode is data: this is the whole of what a
            // program deciding at runtime has to write.
            func names(under mode: TmuxMode) async throws -> [String] {
                try await server.using(mode) { server in
                    try await server.sessions().map(\.name)
                }
            }

            let expected = try await server.sessions().map(\.name)
            let direct = try await names(under: .direct)
            let connected = try await names(under: .connected(to: "bootstrap"))
            #expect(direct == expected)
            #expect(connected == direct)
        }
    }

    @Test("a server says which mode it is in, and the innermost one wins")
    func modeIsReadableAndNests() async throws {
        try await withTmuxServer { server in
            // Rule 2: a server nobody put in a mode is direct.
            #expect(server.mode == .direct)

            try await server.using(.connected(to: "bootstrap")) { connected in
                // Rule 1: the value you were handed reports the mode it carries.
                #expect(connected.mode == .connected(to: "bootstrap"))

                // Rule 2 again: the server captured from outside is untouched.
                #expect(server.mode == .direct)

                // Nesting, innermost first: opting one call out of the
                // connection, and back onto one again.
                try await connected.using(.direct) { direct in
                    #expect(direct.mode == .direct)
                    // Still the same tmux, so it still answers.
                    let sessions = try await direct.sessions()
                    #expect(sessions.contains { $0.name == "bootstrap" })
                }
                try await connected.using(.connected(to: "bootstrap")) { inner in
                    #expect(inner.mode == .connected(to: "bootstrap"))
                }

                // Leaving a nested scope does not disturb the one outside it.
                #expect(connected.mode == .connected(to: "bootstrap"))
            }
        }
    }

    @Test("a hook written over the connection is the same hook")
    func hooksCarryOverTheConnection() async throws {
        try await withTmuxServer { server in
            try await server.connected(attachingTo: "bootstrap") { server, _ in
                _ = try await server.setHook("alert-bell", to: "display-message ding")
            }
            let bound = try #require(
                try await server.hooks().first { $0.name == "alert-bell" }
            )
            #expect(bound.command.contains("display-message"))
        }
    }

    @Test("one connection serves many calls")
    func oneConnectionServesManyCalls() async throws {
        try await withTmuxServer { server in
            let counts = try await server.connected(attachingTo: "bootstrap") { server, _ in
                var counts: [Int] = []
                for index in 0..<5 {
                    _ = try await server.newSession(named: "s\(index)")
                    counts.append(try await server.sessions().count)
                }
                return counts
            }
            // bootstrap plus one more each time round.
            #expect(counts == [2, 3, 4, 5, 6])
        }
    }
}
