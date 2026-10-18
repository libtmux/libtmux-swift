import Foundation
import Testing

@testable import TmuxWorkspaceCLI

/// Every `tmux-workspace` command a Markdown file shows, held to the command
/// tree the executable parses with.
///
/// A README command is prose until something runs it. Parsing it with
/// `WorkspaceRoot.parseAsRoot` is the same step `main` takes before any work
/// starts, so a renamed subcommand, a dropped flag or a missing argument fails
/// here instead of in a reader's shell. Running the command is left to the
/// suites that load, freeze and import against real tmux.
///
/// Reading and parsing the repository takes a second or two on a busy runner.
/// Each case does that on a dispatch thread and records its expectations
/// afterwards, because the suite runs hundreds of cases at once on a pool of
/// as many threads as the machine has cores, and a case that holds one of them
/// delays the cases that wait on a deadline of their own.
@Suite("documented commands", .timeLimit(.minutes(1)))
struct DocumentedCommandsTests {
    private struct Command: Sendable {
        var file: String
        var text: String
        var arguments: [String]
    }

    @Test("every command the documentation shows parses against the real command tree")
    func documentedCommandsParse() async throws {
        let (documents, commands, failures) = try await offThePool {
            let documents = try Self.markdownDocuments()
            var commands: [Command] = []
            for (file, markdown) in documents where markdown.contains("tmux-workspace") {
                commands += Self.commands(in: markdown, file: file)
            }
            return (documents.count, commands, Self.failures(of: commands))
        }
        #expect(documents > 0)
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))

        // An extractor that finds nothing passes every command it never saw.
        // The README shows each of these subcommands, so losing one means the
        // extraction broke or the example was dropped.
        let shown = Set(commands.compactMap { $0.arguments.first { !$0.hasPrefix("-") } })
        for subcommand in ["load", "ls", "search", "freeze", "convert", "import"] {
            #expect(shown.contains(subcommand), Comment(rawValue: subcommand))
        }
    }

    @Test("a command with a bad flag, subcommand or missing argument is reported")
    func badCommandsAreReported() async throws {
        let markdown = """
            ```console
            $ tmux-workspace load --no-such-flag project.yaml
            $ tmux-workspace frobnicate
            $ tmux-workspace load
            $ tmux-workspace import tmuxinator
            $ tmux-workspace load -S /tmp/a.sock -L project project.yaml
            ```
            """
        let commands = Self.commands(in: markdown, file: "sample.md")
        #expect(commands.count == 5)
        let failures = try await offThePool { Self.failures(of: commands) }
        #expect(failures.count == 5)
    }

    @Test("a command that parses is not reported, however it is written")
    func goodCommandsAreNotReported() async throws {
        let markdown = """
            Prose such as $ tmux-workspace nonsense is not a command.

            ```console
            $ tmux-workspace load \\
                -L project \\
                -d \\
                "my project.yaml"
            $ .build/debug/tmux-workspace --help
            $ TMUX_TMPDIR=/tmp/x tmux-workspace ls --json
            $ swift build --product tmux-workspace
            ```

            ```sh
            $ tmux-workspace nonsense
            ```
            """
        let commands = Self.commands(in: markdown, file: "sample.md")
        #expect(
            commands.map(\.arguments) == [
                ["load", "-L", "project", "-d", "my project.yaml"],
                ["--help"],
                ["ls", "--json"],
            ]
        )
        let failures = try await offThePool { Self.failures(of: commands) }
        #expect(failures.isEmpty)
    }

    private static func failures(of commands: [Command]) -> [String] {
        commands.compactMap { command in
            do {
                _ = try WorkspaceRoot.parseAsRoot(command.arguments)
                return nil
            } catch {
                // `--help` and completion generation end the parse with a
                // clean exit, which is the command working.
                if WorkspaceRoot.exitCode(for: error).rawValue == 0 { return nil }
                let reason = WorkspaceRoot.message(for: error)
                return "\(command.file): \(command.text): \(reason)"
            }
        }
    }

    /// The `$ ` lines of every `console` fence that run `tmux-workspace`.
    ///
    /// A trailing backslash joins the next line, as the shell does, so a
    /// command split one flag per line is read as one.
    private static func commands(in markdown: String, file: String) -> [Command] {
        var found: [Command] = []
        var inConsole = false
        var pending: String?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("```") {
                inConsole = text == "```console"
                pending = nil
                continue
            }
            guard inConsole else { continue }
            var command: String
            if let previous = pending {
                command = previous + " " + text.trimmingCharacters(in: .whitespaces)
            } else if text.hasPrefix("$ ") {
                command = String(text.dropFirst(2))
            } else {
                continue
            }
            if command.hasSuffix("\\") {
                command.removeLast()
                pending = command
                continue
            }
            pending = nil
            let words = split(command)
            let program = words.drop(while: { $0.contains("=") && !$0.hasPrefix("-") })
            guard let name = program.first, name.split(separator: "/").last == "tmux-workspace"
            else { continue }
            found.append(
                Command(file: file, text: command, arguments: Array(program.dropFirst()))
            )
        }
        return found
    }

    /// Splits one command line the way a POSIX shell would, up to the first
    /// pipe, redirection or command separator.
    private static func split(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
                started = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character == " " {
                if started { words.append(current) }
                current = ""
                started = false
            } else if "|;&<>".contains(character) {
                break
            } else {
                current.append(character)
                started = true
            }
        }
        if started { words.append(current) }
        return words
    }

    /// Every Markdown file in the repository except the changelog and anything
    /// under a hidden directory such as `.build`.
    private static func markdownDocuments() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { throw CocoaError(.fileReadUnknown) }
        var documents: [(String, String)] = []
        for case let url as URL in enumerator
        where url.pathExtension == "md" && url.lastPathComponent != "CHANGELOG.md" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            documents.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return documents.sorted { $0.0 < $1.0 }
    }
}

/// Runs `work` on a dispatch thread and resumes with its result, so the
/// cooperative pool is not held while it runs.
private func offThePool<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(with: Swift.Result { try work() })
        }
    }
}
