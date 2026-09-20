import Foundation
import Testing

@testable import TmuxWorkspace

@Suite("strict workspace decoding")
struct StrictDecodingTests {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    @Test("a key no level models is refused by name when strict")
    func unmodelledKeysAreRefusedByName() {
        let document = json(
            """
            {"session_name": "s", "options": {},
             "windows": [{"window_name": "w", "shell_command_before": ["cd ~"],
                          "panes": [{"shell_command": ["ls"], "focus": true}]}]}
            """)

        #expect(
            throws: WorkspaceDecodingError.unsupportedKeys([
                "pane.focus", "window.shell_command_before", "workspace.options",
            ])
        ) {
            _ = try Workspace.decode(json: document, strict: true)
        }
    }

    @Test("lenient decoding still drops what it does not model")
    func lenientDecodingKeepsItsBehaviour() throws {
        let document = json(
            """
            {"session_name": "s", "options": {}, "windows": [{"panes": ["ls"]}]}
            """)

        let workspace = try Workspace.decode(json: document)
        #expect(workspace.sessionName == "s")
    }

    @Test("a key inside a command entry is refused the same as one on a pane")
    func unmodelledCommandKeysAreRefused() {
        // tmuxp pauses around a command with these; this type drops them, so a
        // file asking for a pause builds a session that does not pause.
        let document = json(
            """
            {"session_name": "s",
             "windows": [{"panes": [{"shell_command": [{"cmd": "ls", "sleep_before": 1}]}]}]}
            """)

        #expect(throws: WorkspaceDecodingError.unsupportedKeys(["shell_command.sleep_before"])) {
            _ = try Workspace.decode(json: document, strict: true)
        }
    }

    @Test("a command key written on the pane instead is refused")
    func commandKeysOnAPaneAreRefused() {
        // `cmd` is a key of a command entry, so a pane carrying one describes
        // a command this type reads nothing from: it decoded to no commands
        // at all rather than being refused.
        let document = json(
            """
            {"session_name": "s", "windows": [{"panes": [{"cmd": "ls"}]}]}
            """)

        #expect(throws: WorkspaceDecodingError.unsupportedKeys(["pane.cmd"])) {
            _ = try Workspace.decode(json: document, strict: true)
        }
    }

    @Test("a pane-level enter is refused, because this type reads it nowhere")
    func paneLevelEnterIsRefused() {
        // tmuxp takes it and applies it to every command in the pane.
        let document = json(
            """
            {"session_name": "s",
             "windows": [{"panes": [{"shell_command": ["ls"], "enter": false}]}]}
            """)

        #expect(throws: WorkspaceDecodingError.unsupportedKeys(["pane.enter"])) {
            _ = try Workspace.decode(json: document, strict: true)
        }
    }

    @Test("a command entry this type does model passes strict decoding")
    func modelledCommandEntryPassesStrict() throws {
        let document = json(
            """
            {"session_name": "s",
             "windows": [{"panes": [{"shell_command": ["ls", {"cmd": "pwd", "enter": false}]}]}]}
            """)

        let workspace = try Workspace.decode(json: document, strict: true)
        #expect(workspace.windows.first?.panes.first?.shellCommands.count == 2)
        #expect(workspace.windows.first?.panes.first?.shellCommands.last?.enter == false)
    }

    @Test("a document using only modelled keys passes strict decoding")
    func modelledDocumentPassesStrict() throws {
        let document = json(
            """
            {"session_name": "s", "start_directory": "/tmp",
             "windows": [{"window_name": "w", "layout": "tiled",
                          "panes": ["ls", {"shell_command": ["pwd"], "start_directory": "/"}]}]}
            """)

        let workspace = try Workspace.decode(json: document, strict: true)
        #expect(workspace.windows.first?.panes.count == 2)
    }

    #if YAMLWorkspaces
        @Test("the suite's own tmuxp fixture carries keys it never builds")
        func ownFixtureCarriesUnmodelledKeys() throws {
            let url = try #require(
                Bundle.module.url(forResource: "Fixtures/3-pane", withExtension: "yaml"))
            let yaml = try String(contentsOf: url, encoding: .utf8)

            // Decoded leniently this builds without complaint, which is how a
            // `cd ~/` written into the file went unbuilt and unremarked.
            _ = try Workspace.decode(yaml: yaml)
            #expect(throws: WorkspaceDecodingError.unsupportedKeys(["window.shell_command_before"]))
            {
                _ = try Workspace.decode(yaml: yaml, strict: true)
            }
        }
    #endif
}
