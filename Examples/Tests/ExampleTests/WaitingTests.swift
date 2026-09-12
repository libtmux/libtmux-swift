import ExampleCode
import Foundation
import LibTmux
import Testing
import TmuxFixture

/// Whether `make` is on `PATH`, which the channel example runs.
private let makeAvailable: Bool = {
    let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
    return paths.contains { candidate in
        FileManager.default.isExecutableFile(
            atPath: "\(candidate)/make"
        )
    }
}()

private let artifactID = "swift-waiting"

private func onlyPane(_ server: Server) async throws -> Pane {
    try #require(try await server.panes().first)
}

private func assertDocumentedWatchSendsTheDifference(on server: Server) async throws {
    let pane = try await onlyPane(server)
    // `building` false runs the example's setup and leaves the loop
    // immediately, which is the part with a documented contract: the
    // first read establishes a mark rather than dumping the backlog.
    try await watchingForChanges(server, pane: pane, building: false)

    let started = try await server.capture(pane, since: nil)
    #expect(started.lines.isEmpty)
    try await server.run("printf 'watched-line\\n'", in: pane)
    var update = started
    for _ in 0..<30 {
        update = try await server.capture(pane, since: update.cursor)
        if !update.lines.isEmpty { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(update.lines.contains { $0.contains("watched-line") })
}

@Suite("waiting", .timeLimit(.minutes(2)))
struct WaitingTests {
    @Test(
        "the documented channel wait returns when the command signals it",
        .enabled(if: makeAvailable, "the example runs make")
    )
    func documentedChannelWaitReturns() async throws {
        try await withTmuxServer { server in
            // Failure must still signal the channel; otherwise this wait is
            // exactly where the recipe deadlocks.
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("libtmux-swift-waiting-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            try "all:\n\t@false\n".write(
                to: directory.appendingPathComponent("Makefile"),
                atomically: true,
                encoding: .utf8
            )

            let session = try await server.newSession(
                named: "building",
                startDirectory: directory.path
            )
            let pane = try #require(
                try await server.snapshot().panes(of: session).first
            )
            // No assertion beyond returning: the wait either releases or the
            // suite's limit ends it, and a channel nobody signals never
            // releases.
            try await waitingOnAChannel(server, pane: pane)
        }
    }

    @Test("the documented format watch returns on the value it names")
    func documentedFormatWatchReturns() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "work")
            let pane = try #require(
                try await server.snapshot().panes(of: session).first
            )
            // Asserted on being reported at all rather than on what it says:
            // what a pane's shell is called is the platform's business, and an
            // example that waits for one particular name waits forever on the
            // platform that spells it differently.
            let running = try await watchingAFormat(server, pane: pane)
            #expect(running?.isEmpty == false)
        }
    }

    @Test("the documented watch answers the difference and then nothing")
    func documentedWatchSendsTheDifference() async throws {
        let route = try arenaRoute(
            environment: ProcessInfo.processInfo.environment,
            artifact: artifactID
        )
        if case let .arena(socketPath, _) = route {
            let server = try #require(try arenaServer(for: route))
            try await assertDocumentedWatchSendsTheDifference(on: server)
            let evidence = try await arenaEvidence(
                for: server,
                requestedSocket: socketPath,
                artifact: artifactID
            )
            print("LIBTMUX_ARENA_EVIDENCE=\(String(decoding: evidence, as: UTF8.self))")
            return
        }

        try await withTmuxServer { server in
            try await assertDocumentedWatchSendsTheDifference(on: server)
        }
    }

    @Test("the documented output wait ends on the line it was given")
    func documentedOutputWaitMatches() async throws {
        try await withTmuxServer { server in
            let pane = try await onlyPane(server)
            let waited = try await withThrowingTaskGroup(of: OutputWait?.self) { group in
                group.addTask {
                    try await waitingOnOutput(server, pane: pane)
                }
                group.addTask {
                    var round = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        round += 1
                        // Numbered so each attempt is visible in a failed test's
                        // captured tail.
                        try? await server.run(
                            "printf '\\nListening on 80\\(round)\\n'",
                            in: pane
                        )
                    }
                    return nil
                }
                var answer: OutputWait?
                while let outcome = try await group.next() {
                    if let outcome {
                        answer = outcome
                        break
                    }
                }
                group.cancelAll()
                return answer
            }
            #expect(waited?.outcome == .matched)
            #expect(waited?.matched == "Listening on")
        }
    }
}
