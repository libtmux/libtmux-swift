import ExampleCode
import Foundation
import LibTmux
import Testing
import TmuxFixture
import TmuxWorkspace

private let artifactID = "swift-workspaces"

private func assertDocumentedWorkspaceBuilds(on server: Server) async throws {
    let session = try await buildItOnAServer(server, describeAWorkspaceInSwift())
    #expect(session.name == "work")

    let snapshot = try await server.snapshot()
    let windows = snapshot.windows(of: session)
    #expect(windows.map(\.name) == ["editor", "logs"])

    let editor = try #require(windows.first { $0.name == "editor" })
    let panes = snapshot.panes(of: editor)
    #expect(panes.count == 2)
}

@Suite("workspaces", .timeLimit(.minutes(1)))
struct WorkspaceTests {
    @Test("the workspace the README describes is the session tmux ends up with")
    func theDocumentedWorkspaceBuilds() async throws {
        let route = try arenaRoute(
            environment: ProcessInfo.processInfo.environment,
            artifact: artifactID
        )
        if case let .arena(socketPath, _) = route {
            let server = try #require(try arenaServer(for: route))
            try await assertDocumentedWorkspaceBuilds(on: server)
            let evidence = try await arenaEvidence(
                for: server,
                requestedSocket: socketPath,
                artifact: artifactID
            )
            print("LIBTMUX_ARENA_EVIDENCE=\(String(decoding: evidence, as: UTF8.self))")
            return
        }

        try await withTmuxServer { server in
            try await assertDocumentedWorkspaceBuilds(on: server)
        }
    }

    @Test("a workspace written as JSON decodes into the workspace it describes")
    func theDocumentedJSONDecodes() throws {
        let json = Data(
            """
            {"session_name": "work", "windows": [{"window_name": "editor", "panes": [{}]}]}
            """.utf8
        )
        let workspace = try readAWorkspaceWrittenAsJSON(json)
        #expect(workspace.sessionName == "work")
        #expect(workspace.windows.map(\.windowName) == ["editor"])
    }

    @Test("a tmuxp file the README shows decodes into the workspace it describes")
    func theDocumentedTmuxpFileDecodes() throws {
        let workspace = try readATmuxpFile(
            """
            session_name: work
            windows:
              - window_name: editor
                panes:
                  - shell_command: echo hello
            """
        )
        #expect(workspace.sessionName == "work")
        #expect(workspace.windows.map(\.windowName) == ["editor"])
    }
}
