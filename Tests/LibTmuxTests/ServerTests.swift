import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

// MARK: - Endpoint

@Suite("endpoint")
struct EndpointTests {
    @Test("a socket path longer than the portable budget is rejected at construction")
    func overlongSocketPathIsRejected() {
        let path = "/tmp/" + String(repeating: "x", count: 120)
        #expect(throws: TmuxError.self) {
            try Endpoint(socketPath: path)
        }
    }

    @Test("an empty endpoint is rejected")
    func emptyEndpointIsRejected() {
        #expect(throws: TmuxError.invalidEndpoint(.empty)) {
            try Endpoint(socketName: "")
        }
        #expect(throws: TmuxError.invalidEndpoint(.empty)) {
            try Endpoint(socketPath: "")
        }
    }

    @Test("a name and a path address tmux differently")
    func nameAndPathAddressTmuxDifferently() throws {
        #expect(try Endpoint(socketName: "work").addressArguments == ["-L", "work"])
        #expect(try Endpoint(socketPath: "/tmp/s").addressArguments == ["-S", "/tmp/s"])
    }
}

// MARK: - Formats

@Suite("format projection")
struct FormatProjectionTests {
    private let projection = FormatProjection([
        FormatField("session_name"),
        FormatField("session_windows", .integer),
    ])

    private func bytes(_ rows: [[String]], terminated: Bool = true) -> [UInt8] {
        let separator = String(FormatProjection.separator)
        var text = rows.map { $0.joined(separator: separator) }.joined(separator: "\n")
        if terminated, !rows.isEmpty { text += "\n" }
        return Array(text.utf8)
    }

    @Test("the template projects each field once, in order")
    func templateProjectsEachFieldOnceInOrder() {
        #expect(
            projection.template
                == "#{session_name}\(FormatProjection.separator)#{session_windows}"
        )
    }

    @Test("no objects is not one object with empty fields")
    func emptyListingIsNotAnEmptyRow() throws {
        #expect(try projection.decode([]).isEmpty)
        #expect(try projection.decode(bytes([["", "0"]])).count == 1)
    }

    @Test("an unterminated final row still decodes")
    func unterminatedFinalRowDecodes() throws {
        let rows = try projection.decode(bytes([["one", "1"]], terminated: false))
        #expect(rows.count == 1)
    }

    @Test(
        "every representable name round-trips",
        arguments: [
            "", "a b", "a\tb", #"a\b"#, "a'b", #"a"b"#, "a;b", "a$b",
            "#{session_name}", "a#b", "a}b", "å∫ç",
        ]
    )
    func everyRepresentableNameRoundTrips(_ name: String) throws {
        let rows = try projection.decode(bytes([[name, "1"]]))
        #expect(rows.count == 1)
        #expect(rows[0].text(FormatField("session_name")) == name)
    }

    @Test("a value carrying the separator is rejected, not shifted onto its neighbour")
    func separatorInAValueIsRejected() {
        let value = "a\(FormatProjection.separator)b"
        #expect(
            throws: FormatDecodingError.fieldCountMismatch(
                rowIndex: 0,
                expected: 2,
                actual: 3
            )
        ) {
            try projection.decode(bytes([[value, "1"]]))
        }
    }

    @Test("a short row names the row it failed on")
    func shortRowNamesItsIndex() {
        #expect(
            throws: FormatDecodingError.fieldCountMismatch(
                rowIndex: 1,
                expected: 2,
                actual: 1
            )
        ) {
            try projection.decode(bytes([["ok", "1"], ["short"]]))
        }
    }

    @Test("invalid UTF-8 is a typed decoding failure")
    func invalidUTF8IsATypedFailure() {
        var raw: [UInt8] = [0xFF, 0xFE]
        raw.append(contentsOf: bytes([["ok", "1"]]))
        #expect(throws: FormatDecodingError.invalidEncoding(rowIndex: 0)) {
            try projection.decode(raw)
        }
    }

    @Test("a value that is not its declared kind names the field")
    func mistypedValueNamesItsField() {
        #expect(
            throws: FormatDecodingError.invalidValue(
                rowIndex: 0,
                field: "session_windows",
                raw: "many"
            )
        ) {
            try projection.decode(bytes([["ok", "many"]]))
        }
    }
}

// MARK: - Value semantics

@Suite("server value semantics")
struct ServerValueTests {
    @Test("copies of a server share one runtime")
    func copiesShareOneRuntime() throws {
        let server = try Server(socketPath: "/tmp/libtmux-value")
        let copy = server
        #expect(server == copy)
        #expect(server.endpoint == copy.endpoint)
    }

    @Test("two servers on the same endpoint are distinct")
    func distinctServersOnTheSameEndpointAreNotEqual() throws {
        let left = try Server(socketPath: "/tmp/libtmux-value")
        let right = try Server(socketPath: "/tmp/libtmux-value")
        #expect(left != right)
    }
}

@Suite("portability")
struct PortabilityTests {
    @Test("the fixture's socket path fits the budget with room to spare")
    func fixtureSocketPathFitsTheBudget() throws {
        // Every real-tmux test binds a socket at this shape. If the fixture
        // spent the budget, the failure would arrive on the platform with the
        // longest temporary directory rather than here.
        let path = "/tmp/lt-abcdefgh/s"
        #expect(path.utf8.count <= Endpoint.portableSocketPathByteLimit)
        #expect(
            Endpoint.portableSocketPathByteLimit - path.utf8.count >= 80,
            "the fixture should leave most of the budget unspent"
        )
    }

    @Test("the budget is the smaller of the two systems' limits")
    func budgetIsTheSmallerLimit() throws {
        // `sun_path` is 104 bytes on the BSDs and 108 on Linux. Building to the
        // larger one produces paths that bind on Linux and fail on macOS.
        #expect(Endpoint.portableSocketPathByteLimit == 103)

        let atLimit = "/tmp/" + String(repeating: "x", count: 98)
        #expect(atLimit.utf8.count == Endpoint.portableSocketPathByteLimit)
        _ = try Endpoint(socketPath: atLimit)

        #expect(throws: TmuxError.self) {
            try Endpoint(socketPath: atLimit + "x")
        }
    }

    @Test("a multi-byte character costs its bytes, not its length")
    func multiByteCharacterCostsItsBytes() {
        // A path is measured in bytes at the kernel boundary; counting
        // characters would let a Unicode name overrun the limit.
        let path = "/tmp/" + String(repeating: "é", count: 50)
        #expect(path.count == 55)
        #expect(path.utf8.count == 105)
        #expect(throws: TmuxError.self) {
            try Endpoint(socketPath: path)
        }
    }
}

@Suite("real tmux")
struct RealTmuxTests {
    @Test("a fresh server lists the session it was started with")
    func freshServerListsItsBootstrapSession() async throws {
        try await withTmuxServer { server in
            let sessions = try await server.sessions()
            #expect(sessions.count == 1)
            #expect(sessions[0].name == "bootstrap")
            #expect(sessions[0].id.hasPrefix("$"))
            #expect(sessions[0].windowCount >= 1)
            #expect(!sessions[0].isAttached)
        }
    }

    @Test("asking whether a session exists answers without listing them all")
    func hasSessionAnswersByName() async throws {
        try await withTmuxServer { server in
            let bootstrap = try await server.hasSession("bootstrap")
            let absent = try await server.hasSession("never-created")
            #expect(bootstrap)
            #expect(!absent)
        }
    }

    @Test("a session name tmux would otherwise split survives the round trip")
    func adversarialSessionNameSurvivesTheRoundTrip() async throws {
        try await withTmuxServer { server in
            // What survives a requested name is tmux's decision, not ours,
            // and it moves between releases: `:` and `.` are rejected, `#`
            // opens a format sequence, `\` is quoted, and 3.4 quotes `$`
            // where 3.7 does not. These are the characters every supported
            // release keeps.
            let name = #"a b'c"d;e"#
            let created = try await server.run(
                TmuxCommand("new-session", ["-d", "-s", name])
            )
            #expect(created.isSuccess, Comment(rawValue: created.errorText))

            let sessions = try await server.sessions()
            #expect(
                sessions.contains { $0.name == name },
                Comment(rawValue: "requested \(name); observed \(sessions.map(\.name))")
            )
        }
    }

    @Test("tmux expands a format sequence in a requested session name")
    func requestedSessionNameIsFormatExpanded() async throws {
        try await withTmuxServer { server in
            // `-s` is expanded before the session exists, so the sequence
            // resolves to nothing rather than being stored literally. A caller
            // who wants a literal `#` has to know this.
            let created = try await server.run(
                TmuxCommand("new-session", ["-d", "-s", "keep#{session_name}"])
            )
            #expect(created.isSuccess, Comment(rawValue: created.errorText))

            let sessions = try await server.sessions()
            #expect(sessions.contains { $0.name == "keep" })
            #expect(!sessions.contains { $0.name.contains("#") })
        }
    }

    @Test("tmux quotes a backslash in a requested session name")
    func requestedSessionNameDoublesBackslashes() async throws {
        try await withTmuxServer { server in
            let created = try await server.run(
                TmuxCommand("new-session", ["-d", "-s", #"x\y"#])
            )
            #expect(created.isSuccess, Comment(rawValue: created.errorText))

            // The stored name, not the format layer: plain `list-sessions`
            // shows the same doubling.
            let sessions = try await server.sessions()
            let stored = try #require(sessions.first { $0.name != "bootstrap" })
            #expect(stored.name.hasPrefix("x"))
            #expect(stored.name.hasSuffix("y"))
        }
    }

    @Test("a fresh server lists one window and one pane, related by id")
    func freshServerListsRelatedWindowAndPane() async throws {
        try await withTmuxServer { server in
            let sessions = try await server.sessions()
            let windows = try await server.windows()
            let panes = try await server.panes()

            let session = try #require(sessions.first)
            #expect(windows.count == 1)
            #expect(panes.count == 1)

            let window = try #require(windows.first)
            let pane = try #require(panes.first)
            #expect(window.id.hasPrefix("@"))
            #expect(pane.id.hasPrefix("%"))
            #expect(window.sessionID == session.id)
            #expect(pane.windowID == window.id)
            #expect(pane.sessionID == session.id)
            #expect(window.isActive)
            #expect(pane.isActive)
            #expect(pane.width > 0)
            #expect(pane.height > 0)
        }
    }

    @Test("splitting a window relates both panes to the same window")
    func splittingAWindowRelatesBothPanes() async throws {
        try await withTmuxServer { server in
            let split = try await server.run(
                TmuxCommand("split-window", ["-d", "-t", "bootstrap"])
            )
            #expect(split.isSuccess, Comment(rawValue: split.errorText))

            let windows = try await server.windows()
            let panes = try await server.panes()
            let window = try #require(windows.first)
            #expect(window.paneCount == 2)
            #expect(panes.count == 2)
            #expect(panes.allSatisfy { $0.windowID == window.id })
            #expect(Set(panes.map(\.id)).count == 2)
            #expect(panes.filter(\.isActive).count == 1)
        }
    }

    @Test("a detached server has no clients")
    func detachedServerHasNoClients() async throws {
        try await withTmuxServer { server in
            let clients = try await server.clients()
            #expect(clients.isEmpty)
        }
    }

    @Test("listings are values that do not re-read tmux")
    func listingsAreValues() async throws {
        try await withTmuxServer { server in
            let before = try await server.windows()
            _ = try await server.run(
                TmuxCommand("new-window", ["-d", "-t", "bootstrap"])
            )
            // The array taken before the change still describes what it saw.
            #expect(before.count == 1)
            let after = try await server.windows()
            #expect(after.count == 2)
        }
    }

    @Test("a rejected command is a reply, not a thrown error")
    func rejectedCommandIsAReply() async throws {
        try await withTmuxServer { server in
            let reply = try await server.run(
                TmuxCommand("has-session", ["-t", "no-such-session"])
            )
            #expect(!reply.isSuccess)
            #expect(!reply.errorText.isEmpty)
        }
    }

    @Test("a server that was never started reports no sessions and is not running")
    func absentServerIsEmptyAndNotRunning() async throws {
        let server = try Server(
            socketPath: "/tmp/lt-absent-\(UUID().uuidString.prefix(8))",
            tmuxExecutable: tmuxExecutablePath()
        )
        let sessions = try await server.sessions()
        #expect(sessions.isEmpty)
        let running = try await server.isRunning()
        #expect(!running)
    }

    @Test("killing the server leaves nothing listening")
    func killingTheServerLeavesNothingListening() async throws {
        var captured: Server?
        try await withTmuxServer { server in
            captured = server
            let running = try await server.isRunning()
            #expect(running)
        }
        let server = try #require(captured)
        let running = try await server.isRunning()
        #expect(!running)
    }
}

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

@Suite("socket address budget")
struct SocketAddressBudgetTests {
    /// The limit is a constant chosen for the smallest `sun_path` the library
    /// claims to run on. Nothing checked it against the platform actually
    /// running, so an assumption about Darwin held only until someone read the
    /// comment. This asks the C type instead.
    @Test("the advertised limit fits the address this platform binds")
    func advertisedLimitFitsTheRealAddress() {
        let address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)

        // A path spends `capacity` bytes less the terminating NUL.
        #expect(Endpoint.portableSocketPathByteLimit <= capacity - 1)
    }
}
