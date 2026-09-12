import ExampleCode
import Foundation
import LibTmux
import Testing
import TmuxFixture

private let artifactID = "swift-changing"

private func assertDocumentedSessionBuilt(on server: Server) async throws {
    let pane = try await buildASessionByHand(server)

    let snapshot = try await server.snapshot()
    #expect(snapshot.sessions.contains { $0.name == "work" })

    let work = try #require(snapshot.sessions.first { $0.name == "work" })
    #expect(
        try await server.option("@purpose", scope: .session(work)) == "development"
    )
    let windows = snapshot.windows(of: work)
    #expect(windows.map(\.name).sorted() == ["editor", "logs"])

    let logs = try #require(windows.first { $0.name == "logs" })
    let panes = snapshot.panes(of: logs)
    #expect(panes.count == 2)
    #expect(panes.contains { $0.id == pane.id })
}

@Suite("changing", .timeLimit(.minutes(1)))
struct ChangingTests {
    @Test("the session the README builds is the session tmux ends up with")
    func theDocumentedSessionIsBuilt() async throws {
        let route = try arenaRoute(
            environment: ProcessInfo.processInfo.environment,
            artifact: artifactID
        )
        if case let .arena(socketPath, _) = route {
            let server = try #require(try arenaServer(for: route))
            try await assertDocumentedSessionBuilt(on: server)
            let evidence = try await arenaEvidence(
                for: server,
                requestedSocket: socketPath,
                artifact: artifactID
            )
            print("LIBTMUX_ARENA_EVIDENCE=\(String(decoding: evidence, as: UTF8.self))")
            return
        }

        try await withTmuxServer { server in
            try await assertDocumentedSessionBuilt(on: server)
        }
    }

    @Test("capture reads back what a pane printed")
    func captureReadsBackWhatWasPrinted() async throws {
        try await withTmuxServer { server in
            let marker = "libtmux-capture-marker"
            let pane = try #require(try await server.panes().first)
            _ = try await server.run(
                TmuxCommand("send-keys", ["-t", pane.id.rawValue, "echo \(marker)", "Enter"])
            )
            let arrived = try await waitUntil {
                try await readBackWhatAPanePrinted(server, pane)
                    .contains { $0.contains(marker) }
            }
            #expect(arrived, "the marker never reached the pane's history")
        }
    }

    @Test("a command list spends one invocation on all of it")
    func aCommandListSpendsOneInvocation() async throws {
        try await withTmuxServer { server in
            try await spendOneProcessOnAllOfIt(server)
            let names = try await server.windows().map(\.name)
            for wanted in ["edit", "test", "logs"] {
                #expect(names.contains(wanted), "window \(wanted) was not created")
            }
        }
    }
}
