import Foundation
import Testing

@testable import LibTmuxMCP

/// What the Markdown says about the MCP server, held to what the code does.
///
/// A tool table that names a tool the registry dropped, a link to a page that
/// does not exist, or a client configuration the executable refuses at startup
/// all read fine on the page. These cases read the documents the same way a
/// reader does and compare them with the registry and with
/// `ServerConfiguration`, which is the parse `libtmux-mcp` runs before it opens
/// a socket.
@Suite("MCP documentation", .timeLimit(.minutes(1)))
struct ReadmeDocumentationTests {
    private static let toolPages = "https://libtmux.org/en/swift/latest/mcp/tools/"

    @Test("every tool name the Markdown links points at that tool's own page")
    func toolLinksPointAtTheirPages() throws {
        let tools = Set(TmuxTools.definitions.map(\.name))
        let documents = try Self.markdownDocuments()
        for (file, markdown) in documents {
            let defined = Self.toolDefinitions(in: markdown, tools: tools)
            for (name, url) in defined {
                #expect(
                    tools.contains(name) && url == "\(Self.toolPages)\(name)/",
                    Comment(rawValue: "\(file): \(name) links to \(url)")
                )
            }
            for name in Self.toolLinkUses(in: markdown, tools: tools) {
                #expect(
                    defined[name] != nil,
                    Comment(rawValue: "\(file): [`\(name)`] has no link definition")
                )
            }
        }

        // The root page and the executable's page are the two that list the
        // tools, so each carries a link for all of them.
        for file in ["README.md", "Sources/libtmux-mcp/README.md"] {
            let markdown = try #require(documents.first { $0.0 == file }?.1)
            let defined = Self.toolDefinitions(in: markdown, tools: tools)
            for name in tools.sorted() {
                #expect(defined[name] != nil, Comment(rawValue: "\(file): \(name) is not linked"))
            }
        }
    }

    @Test("the executable's toolset table lists each toolset's tools and no others")
    func toolsetTableMatchesTheRegistry() throws {
        let documents = try Self.markdownDocuments()
        let markdown = try #require(
            documents.first { $0.0 == "Sources/libtmux-mcp/README.md" }?.1
        )
        let rows = markdown.split(separator: "\n").filter { $0.hasPrefix("| `") }
        for toolset in Toolset.allCases {
            let row = try #require(
                rows.first { $0.hasPrefix("| `\(toolset.rawValue)` |") },
                Comment(rawValue: toolset.rawValue)
            )
            let cell = try #require(row.split(separator: "|").last)
            let listed = Set(cell.matches(of: #/\[`([a-z_]+)`\]/#).map { String($0.output.1) })
            let registered = Set(
                TmuxTools.definitions.filter { $0.toolset == toolset }.map(\.name)
            )
            #expect(listed == registered, Comment(rawValue: toolset.rawValue))
        }
    }

    @Test("every client configuration the Markdown shows starts the server cleanly")
    func documentedConfigurationsAreAccepted() throws {
        var environments: [(String, [String: String])] = []
        for (file, markdown) in try Self.markdownDocuments() {
            environments += Self.environments(in: markdown).map { (file, $0) }
        }
        #expect(!environments.isEmpty)

        for (file, environment) in environments {
            let configuration = ServerConfiguration(environment: environment)
            let reason = "\(file): \(environment.sorted { $0.key < $1.key })"
            #expect(
                configuration.errors.isEmpty, Comment(rawValue: "\(reason) \(configuration.errors)")
            )
            #expect(
                configuration.warnings.isEmpty,
                Comment(rawValue: "\(reason) \(configuration.warnings)")
            )
        }

        // An extractor that finds nothing accepts everything it never saw.
        let documented = Set(environments.flatMap { $0.1.keys })
        for variable in [
            "LIBTMUX_SOCKET", "LIBTMUX_TOOLSETS", "LIBTMUX_TOOLS", "LIBTMUX_EXCLUDE_TOOLS",
        ] {
            #expect(documented.contains(variable), Comment(rawValue: variable))
        }
    }

    @Test("a configuration the server would refuse is reported, and a good one is not")
    func badConfigurationsAreReported() {
        let markdown = """
            ```console
            $ claude mcp add tmux \\
                -e LIBTMUX_TOOLSETS=bogus \\
                -- /path/to/libtmux-mcp
            $ claude mcp add tmux -e LIBTMUX_TOOLS=no_such_tool -- /path/to/libtmux-mcp
            $ claude mcp add tmux -e LIBTMUX_SAFETY=full -- /path/to/libtmux-mcp
            $ claude mcp add tmux -e LIBTMUX_SOCKET=a -e LIBTMUX_SOCKET_PATH=/b -- libtmux-mcp
            ```

            ```json
            {"mcpServers": {"tmux": {"command": "x", "env": {"LIBTMUX_TOOLSETS": "bogus"}}}}
            ```
            """
        let rejected = Self.environments(in: markdown).map {
            ServerConfiguration(environment: $0).errors.isEmpty
        }
        #expect(rejected == [false, false, false, false, false])

        let accepted = Self.environments(
            in: """
                ```console
                $ claude mcp add tmux \\
                    -e LIBTMUX_TOOLSETS= \\
                    -e LIBTMUX_TOOLS=list_sessions,capture_pane \\
                    -- /path/to/libtmux-mcp
                ```
                """)
        #expect(
            accepted == [["LIBTMUX_TOOLSETS": "", "LIBTMUX_TOOLS": "list_sessions,capture_pane"]])
        #expect(ServerConfiguration(environment: accepted[0]).errors.isEmpty)
    }

    @Test("a link to the wrong page, or to a tool the registry lacks, is reported")
    func badToolLinksAreReported() {
        let tools: Set = ["list_sessions", "capture_pane", "send_keys"]
        let markdown = """
            [`list_sessions`] and [`capture_pane`] and [`send_keys`]

            | [`list_sessions`] [`capture_pane`] | text |

            [`list_sessions`]: \(Self.toolPages)list_sessions/
            [`capture_pane`]: \(Self.toolPages)capture_panes/
            [`no_such_tool`]: \(Self.toolPages)no_such_tool/
            """
        #expect(
            Self.toolLinkUses(in: markdown, tools: tools)
                == ["list_sessions", "capture_pane", "send_keys"]
        )
        let defined = Self.toolDefinitions(in: markdown, tools: tools)
        #expect(defined["list_sessions"] == "\(Self.toolPages)list_sessions/")
        #expect(defined["capture_pane"] == "\(Self.toolPages)capture_panes/")
        #expect(defined["send_keys"] == nil)
        #expect(defined["no_such_tool"] == "\(Self.toolPages)no_such_tool/")
        #expect(!tools.contains("no_such_tool"))
    }

    /// `[`name`]: URL` lines whose name is a tool or whose URL is a tool page.
    private static func toolDefinitions(in markdown: String, tools: Set<String>) -> [String: String]
    {
        var found: [String: String] = [:]
        for line in markdown.split(separator: "\n") {
            guard let match = line.wholeMatch(of: #/\[`([a-z_]+)`\]: (\S+)/#) else { continue }
            let name = String(match.output.1)
            let url = String(match.output.2)
            if tools.contains(name) || url.hasPrefix(toolPages) { found[name] = url }
        }
        return found
    }

    /// Shortcut references such as ``[`list_sessions`]`` that are tools, in
    /// order of first use. Definitions and full references are not uses.
    private static func toolLinkUses(in markdown: String, tools: Set<String>) -> [String] {
        var seen: [String] = []
        for line in markdown.split(separator: "\n")
        where line.firstMatch(of: #/^\[`[a-z_]+`\]: /#) == nil {
            for match in line.matches(of: #/\[`([a-z_]+)`\](?![(:\[])/#) {
                let name = String(match.output.1)
                if tools.contains(name), !seen.contains(name) { seen.append(name) }
            }
        }
        return seen
    }

    /// The `env` of every `mcpServers` entry in a `json` fence, and the `-e`
    /// settings of every `claude mcp add` command in a `console` fence.
    private static func environments(in markdown: String) -> [[String: String]] {
        var found: [[String: String]] = []
        var fence: String?
        var body: [String] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("```") {
                if let opened = fence {
                    found += environments(inFence: opened, lines: body)
                    fence = nil
                } else {
                    fence = String(text.dropFirst(3))
                    body = []
                }
            } else if fence != nil {
                body.append(text)
            }
        }
        return found
    }

    private static func environments(inFence kind: String, lines: [String]) -> [[String: String]] {
        if kind == "json" {
            let text = lines.joined(separator: "\n")
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                let servers = root["mcpServers"] as? [String: Any]
            else { return [] }
            return servers.values.compactMap { ($0 as? [String: Any])?["env"] as? [String: String] }
        }
        guard kind == "console" else { return [] }
        var commands: [String] = []
        var pending: String?
        for line in lines {
            var command: String
            if let previous = pending {
                command = previous + " " + line.trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("$ ") {
                command = String(line.dropFirst(2))
            } else {
                continue
            }
            if command.hasSuffix("\\") {
                command.removeLast()
                pending = command
            } else {
                pending = nil
                commands.append(command)
            }
        }
        return commands.compactMap { command in
            let words = command.split(separator: " ").map(String.init)
            guard words.starts(with: ["claude", "mcp", "add"]) else { return nil }
            var environment: [String: String] = [:]
            var index = words.startIndex
            while index < words.endIndex, words[index] != "--" {
                if words[index] == "-e" || words[index] == "--env", index + 1 < words.endIndex {
                    let pair = words[index + 1]
                    if let equals = pair.firstIndex(of: "=") {
                        environment[String(pair[..<equals])] = String(
                            pair[pair.index(after: equals)...])
                    }
                    index += 1
                }
                index += 1
            }
            return environment
        }
    }

    /// Every Markdown file in the repository except the changelog and anything
    /// under a hidden directory such as `.build`.
    private static func markdownDocuments() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        var documents: [(String, String)] = []
        for case let url as URL in enumerator
        where url.pathExtension == "md" && url.lastPathComponent != "CHANGELOG.md" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            documents.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return documents.sorted { $0.0 < $1.0 }
    }
}
