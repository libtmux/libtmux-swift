import Foundation
import Testing

@testable import WorkspaceBuilder

/// tmuxp ships each example twice, as YAML and as JSON. Decoding both and
/// comparing tests the two readers against each other over files this project
/// did not write — a stronger claim than either parsing on its own.
///
/// See `Fixtures/NOTICE.md` for where these came from and why these ones.
@Suite("tmuxp fixtures")
struct TmuxpFixtureTests {
    static let names = [
        "2-pane-vertical", "3-pane", "blank-panes", "skip-send", "sleep",
    ]

    @Test("both spellings of an example describe the same workspace", arguments: names)
    func spellingsAgree(_ name: String) throws {
        let yamlURL = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "yaml")
        )
        let jsonURL = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        )

        let fromYAML = try Workspace.decode(
            yaml: String(contentsOf: yamlURL, encoding: .utf8)
        )
        let fromJSON = try Workspace.decode(json: Data(contentsOf: jsonURL))

        #expect(fromYAML == fromJSON)
        #expect(!fromYAML.windows.isEmpty)
    }

    @Test("a blank pane survives every way tmuxp writes one")
    func blankPanesDecode() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/blank-panes", withExtension: "yaml")
        )
        let workspace = try Workspace.decode(
            yaml: String(contentsOf: url, encoding: .utf8)
        )

        // Every pane in the file is present, and the blank ones carry no
        // commands rather than being dropped.
        let panes = workspace.windows.flatMap(\.panes)
        #expect(panes.count > 3)
        #expect(panes.contains { $0.shellCommands.isEmpty })
    }

    @Test("a command written the long way keeps its enter")
    func longFormCommandKeepsEnter() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/skip-send", withExtension: "yaml")
        )
        let workspace = try Workspace.decode(
            yaml: String(contentsOf: url, encoding: .utf8)
        )

        let commands = workspace.windows.flatMap(\.panes).flatMap(\.shellCommands)
        #expect(commands.contains { $0.enter })
        #expect(commands.contains { !$0.enter })
    }
}
