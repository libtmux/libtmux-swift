#if YAMLWorkspaces

    import Foundation
    import Testing

    @testable import WorkspaceBuilder

    /// The YAML reader lives behind the `YAMLWorkspaces` trait, so its tests do
    /// too. Keeping them in their own file makes the boundary a file boundary
    /// rather than a conditional wrapped around half a suite.
    @Suite("workspace decoding, YAML")
    struct YAMLDecodingTests {
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
    }

#endif
