import ExampleCode
import Foundation
import LibTmux
import Testing
import TmuxFixture
import TmuxWorkspace

@Suite("workspaces", .timeLimit(.minutes(1)))
struct WorkspaceTests {
    @Test("the workspace the README describes is the session tmux ends up with")
    func theDocumentedWorkspaceBuilds() async throws {
        try await withTmuxServer { server in
            let session = try await buildItOnAServer(server, describeAWorkspaceInSwift())
            #expect(session.name == "work")

            let windows = try await server.windows().filter { $0.sessionID == session.id }
            #expect(windows.map(\.name) == ["editor", "logs"])

            let editor = try #require(windows.first { $0.name == "editor" })
            let panes = try await server.panes().filter { $0.windowID == editor.id }
            #expect(panes.count == 2)
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
