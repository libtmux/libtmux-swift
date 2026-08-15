import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import WorkspaceBuilder

@Suite("workspace decoding", .timeLimit(.minutes(1)))
struct WorkspaceDecodingTests {
    @Test("a tmuxp file decodes through its own key names")
    func tmuxpFileDecodes() throws {
        let json = Data(
            """
            {
              "session_name": "work",
              "start_directory": "/tmp",
              "windows": [
                {
                  "window_name": "editor",
                  "layout": "even-horizontal",
                  "panes": [{"shell_command": ["echo one"]}, "echo two"]
                }
              ]
            }
            """.utf8
        )
        let workspace = try Workspace.decode(json: json)
        #expect(workspace.sessionName == "work")
        #expect(workspace.startDirectory == "/tmp")
        #expect(workspace.windows.count == 1)

        let window = try #require(workspace.windows.first)
        #expect(window.windowName == "editor")
        #expect(window.layout == "even-horizontal")
        // tmuxp lets a pane be a bare string meaning "run this".
        #expect(window.panes.map(\.shellCommands) == [["echo one"], ["echo two"]])
    }

    @Test("a tmux-flavoured scalar reaches a string field as itself")
    func booleanLookingScalarsStayText() throws {
        // YAML 1.1 reads `on`, `yes`, and `no` as booleans and 1.2 as strings,
        // which would be a hazard for a format full of tmux options — except
        // that decoding here is driven by the type. A `String` field asks for a
        // string, so the ambiguity never gets a vote.
        let workspace = try Workspace.decode(
            yaml: """
                session_name: flags
                windows:
                  - window_name: on
                    panes:
                      - no
                      - yes
                      - off
                """
        )
        let window = try #require(workspace.windows.first)
        #expect(window.windowName == "on")
        #expect(window.panes.map(\.shellCommands) == [["no"], ["yes"], ["off"]])
    }

    @Test("a blank pane is a pane, in either spelling")
    func blankPaneIsStillAPane() throws {
        // tmuxp writes a pane with nothing to run as null, meaning "just a
        // shell here". Both readers have to agree that is a pane, not an
        // absence.
        let fromJSON = try Workspace.decode(
            json: Data(
                #"{"session_name": "s", "windows": [{"panes": [null, "echo"]}]}"#
                    .utf8
            )
        )
        let fromYAML = try Workspace.decode(
            yaml: """
                session_name: s
                windows:
                  - panes:
                      -
                      - echo
                """
        )

        #expect(fromJSON == fromYAML)
        let panes = try #require(fromJSON.windows.first?.panes)
        #expect(panes.count == 2)
        #expect(panes.first?.shellCommands == [])
    }

    @Test("a null among the commands is no command")
    func nullCommandIsDropped() throws {
        // tmuxp spells a blank pane three ways, and this is the third: the
        // pane is there, its command list is there, and the command is not.
        let workspace = try Workspace.decode(
            json: Data(
                """
                {"session_name": "s", "windows": [{"panes": [
                  {"shell_command": [null]},
                  {"shell_command": null}
                ]}]}
                """.utf8
            )
        )
        let panes = try #require(workspace.windows.first?.panes)
        #expect(panes.map(\.shellCommands) == [[], []])
    }

    @Test("a command can ask to be typed but not run")
    func commandCanDeclineEnter() throws {
        // tmuxp's long form for a command: `enter: false` puts it in the pane
        // ready to run, without running it.
        let workspace = try Workspace.decode(
            yaml: """
                session_name: s
                windows:
                  - panes:
                      - shell_command:
                          - echo one
                          - cmd: echo two
                            enter: false
                """
        )
        let pane = try #require(workspace.windows.first?.panes.first)
        #expect(pane.shellCommands == ["echo one", ShellCommand("echo two", enter: false)])
    }

    @Test("shell_command decodes whether it is one string or several")
    func shellCommandDecodesEitherSpelling() throws {
        let json = Data(
            """
            {"session_name": "s", "windows": [{"panes": [
              {"shell_command": "one"},
              {"shell_command": ["two", "three"]},
              {}
            ]}]}
            """.utf8
        )
        let workspace = try Workspace.decode(json: json)
        let panes = try #require(workspace.windows.first?.panes)
        #expect(panes.map(\.shellCommands) == [["one"], ["two", "three"], []])
    }
}

@Suite("workspace building", .timeLimit(.minutes(1)))
struct WorkspaceBuildingTests {
    @Test("a workspace becomes the session, windows, and panes it describes")
    func workspaceBecomesWhatItDescribes() async throws {
        try await withTmuxServer { server in
            let workspace = Workspace(
                sessionName: "built",
                windows: [
                    WindowPlan(windowName: "editor", panes: [PanePlan(), PanePlan()]),
                    WindowPlan(windowName: "shell", panes: [PanePlan()]),
                ]
            )
            let session = try await WorkspaceBuilder.build(workspace, on: server)
            #expect(session.name == "built")

            let snapshot = try await server.snapshot()
            let windows = snapshot.windows(of: session)
            #expect(windows.map(\.name) == ["editor", "shell"])

            let editor = try #require(windows.first)
            #expect(snapshot.panes(of: editor).count == 2)
            #expect(snapshot.panes(of: session).count == 3)
        }
    }

    @Test("a start directory reaches the panes it applies to")
    func startDirectoryReachesItsPanes() async throws {
        try await withTmuxServer { server in
            let workspace = Workspace(
                sessionName: "dirs",
                startDirectory: "/tmp",
                windows: [WindowPlan(panes: [PanePlan()])]
            )
            let session = try await WorkspaceBuilder.build(workspace, on: server)

            let snapshot = try await server.snapshot()
            let pane = try #require(snapshot.panes(of: session).first)
            // Darwin makes `/tmp` a symlink to `/private/tmp`, and tmux reports
            // where the pane actually is, not the name it was asked for.
            let expected = URL(fileURLWithPath: "/tmp")
                .resolvingSymlinksInPath().path
            #expect(pane.currentPath == expected)
        }
    }

    @Test("a layout is applied once the panes exist")
    func layoutIsAppliedAfterThePanes() async throws {
        try await withTmuxServer { server in
            let workspace = Workspace(
                sessionName: "laid-out",
                windows: [
                    WindowPlan(
                        layout: "even-horizontal",
                        panes: [PanePlan(), PanePlan()]
                    )
                ]
            )
            let session = try await WorkspaceBuilder.build(workspace, on: server)

            let snapshot = try await server.snapshot()
            let panes = snapshot.panes(of: session)
            #expect(panes.count == 2)
            // even-horizontal splits the width, so the panes are side by side.
            #expect(panes[0].height == panes[1].height)
        }
    }

    @Test("building over an existing session is refused, not merged into it")
    func buildingOverAnExistingSessionIsRefused() async throws {
        try await withTmuxServer { server in
            let workspace = Workspace(
                sessionName: "once",
                windows: [WindowPlan(panes: [PanePlan()])]
            )
            _ = try await WorkspaceBuilder.build(workspace, on: server)

            await #expect(throws: WorkspaceBuilderError.sessionExists("once")) {
                try await WorkspaceBuilder.build(workspace, on: server)
            }
        }
    }

    @Test("a workspace with no windows is refused before anything is created")
    func emptyWorkspaceIsRefused() async throws {
        try await withTmuxServer { server in
            await #expect(throws: WorkspaceBuilderError.noWindows) {
                try await WorkspaceBuilder.build(
                    Workspace(sessionName: "empty", windows: []),
                    on: server
                )
            }
            let sessions = try await server.sessions()
            #expect(!sessions.contains { $0.name == "empty" })
        }
    }

    @Test("a command that declines enter is typed but not run")
    func declinedEnterIsTypedNotRun() async throws {
        try await withTmuxServer { server in
            let workspace = Workspace(
                sessionName: "unrun",
                windows: [
                    WindowPlan(panes: [
                        PanePlan(shellCommands: [ShellCommand("sleep 43", enter: false)])
                    ])
                ]
            )
            let session = try await WorkspaceBuilder.build(workspace, on: server)
            let pane = try #require(
                try await server.snapshot().panes(of: session).first
            )

            // The text is sitting on the prompt.
            let typed = try await waitUntil {
                try await server.capture(pane).contains { $0.contains("sleep 43") }
            }
            #expect(typed)

            // And it never became the running command, which `sleep 41` does
            // in the case above.
            let running = try await server.panes()
                .first { $0.id == pane.id }?.currentCommand
            #expect(running != "sleep")
        }
    }

    @Test("a shell command reaches the pane it was written for")
    func shellCommandReachesItsPane() async throws {
        try await withTmuxServer { server in
            let workspace = Workspace(
                sessionName: "running",
                windows: [
                    WindowPlan(panes: [PanePlan(shellCommands: ["sleep 41"])])
                ]
            )
            let session = try await WorkspaceBuilder.build(workspace, on: server)
            let built = try #require(
                try await server.snapshot().windows(of: session).first
            )

            // Poll rather than sleep: the shell needs a moment to exec.
            let running = try await waitUntil {
                // panes() is one tmux invocation; snapshot() is six.
                try await server.panes()
                    .first { $0.windowID == built.id }?.currentCommand == "sleep"
            }
            #expect(running)
        }
    }
}
