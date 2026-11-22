import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

/// tmux prints an environment value with its raw newlines, so a value holding
/// one has to be told apart from the next variable's line.
///
/// A client that is not UTF-8 gets `_` for the newline, and there is nothing to
/// tell apart then; these cases run only where the client is UTF-8.
private let clientIsUTF8: Bool = {
    let environment = ProcessInfo.processInfo.environment
    let locale = ["LC_ALL", "LC_CTYPE", "LANG"].compactMap { environment[$0] }
        .first { !$0.isEmpty }
    return locale?.lowercased().contains("utf-8") == true
        || locale?.lowercased().contains("utf8") == true
}()

@Suite("environment listing", .timeLimit(.minutes(5)))
struct EnvironmentListingTests {
    @Test(
        "dollar escapes printed by tmux 3.3a and 3.4 keep the same value",
        arguments: [
            (#"\$HOME"#, "$HOME"),
            (#"\\$HOME"#, "$HOME"),
            (#"\\\$HOME"#, #"\$HOME"#),
            (#"\\\\$HOME"#, #"\$HOME"#),
        ])
    func dollarEscapes(_ quotedValue: String, _ value: String) {
        let text = "SWIFTPROBE_A=\"\(quotedValue)\"; export SWIFTPROBE_A;\n"
        #expect(
            TmuxEnvironmentVariable.variables(shellListing: text)
                == [TmuxEnvironmentVariable(name: "SWIFTPROBE_A", value: value)])
    }

    @Test(
        "a value with a newline is one variable, not two",
        .enabled(if: clientIsUTF8, "the client must be UTF-8 for tmux to print the newline"))
    func newlineInAValueIsNotAVariable() async throws {
        try await withTmuxServer { server in
            let value = "first\nSWIFTPROBE_B=second"
            _ = try await server.setEnvironment("SWIFTPROBE_A", to: value)

            let whole = try await server.environmentValue("SWIFTPROBE_A")
            #expect(whole == value)

            let listed = try await server.environment().filter {
                $0.name.hasPrefix("SWIFTPROBE_")
            }
            #expect(listed == [TmuxEnvironmentVariable(name: "SWIFTPROBE_A", value: value)])
        }
    }

    @Test(
        "quotes, backslashes and shell syntax in a value stay in the value",
        .enabled(if: clientIsUTF8, "the client must be UTF-8 for tmux to print the newline"))
    func shellSyntaxInAValueStaysInTheValue() async throws {
        try await withTmuxServer { server in
            let value = "a\"; export SWIFTPROBE_C;\nunset SWIFTPROBE_D;\n\\ $HOME `x`\n"
            _ = try await server.setEnvironment("SWIFTPROBE_A", to: value)
            _ = try await server.setEnvironment("SWIFTPROBE_E", to: "after")
            _ = try await server.removeEnvironment("SWIFTPROBE_F")
            #expect(try await server.environmentValue("SWIFTPROBE_A") == value)

            let listed = try await server.environment().filter {
                $0.name.hasPrefix("SWIFTPROBE_")
            }
            #expect(
                listed == [
                    TmuxEnvironmentVariable(name: "SWIFTPROBE_A", value: value),
                    TmuxEnvironmentVariable(name: "SWIFTPROBE_E", value: "after"),
                    TmuxEnvironmentVariable(name: "SWIFTPROBE_F", value: nil),
                ]
            )
        }
    }

    @Test("dollar text keeps its literal backslashes")
    func dollarsKeepLiteralBackslashes() async throws {
        try await withTmuxServer { server in
            for suffix in ["$HOME", "${name}", "$_name", "$9", "$", "$-"] {
                for count in 0...3 {
                    let value = String(repeating: "\\", count: count) + suffix
                    _ = try await server.setEnvironment("SWIFTPROBE_A", to: value)
                    #expect(try await server.environmentValue("SWIFTPROBE_A") == value)

                    let listed = try await server.environment().filter {
                        $0.name == "SWIFTPROBE_A"
                    }
                    #expect(listed == [TmuxEnvironmentVariable(name: "SWIFTPROBE_A", value: value)])
                }
            }
        }
    }

    @Test("an individual read keeps tmux's spelling for carriage returns")
    func carriageReturnSpellingIsPreserved() async throws {
        try await withTmuxServer { server in
            for value in ["one\rtwo", #"one\rtwo"#, #"one\qtwo"#] {
                _ = try await server.setEnvironment("SWIFTPROBE_A", to: value)
                let reply = try await server.run(
                    TmuxCommand("show-environment", ["-g", "SWIFTPROBE_A"]))
                #expect(reply.isSuccess)
                let expected = String(reply.text.dropFirst("SWIFTPROBE_A=".count).dropLast())
                #expect(try await server.environmentValue("SWIFTPROBE_A") == expected)
            }
        }
    }

    @Test("a plain listing keeps each variable, its empty values and its removals")
    func plainListing() async throws {
        try await withTmuxServer { server in
            _ = try await server.setEnvironment("SWIFTPROBE_A", to: "one two")
            _ = try await server.setEnvironment("SWIFTPROBE_B", to: "")
            _ = try await server.removeEnvironment("SWIFTPROBE_C")
            _ = try await server.setEnvironment("SWIFTPROBE_D", to: "a=b;")

            let listed = try await server.environment().filter {
                $0.name.hasPrefix("SWIFTPROBE_")
            }
            #expect(
                listed == [
                    TmuxEnvironmentVariable(name: "SWIFTPROBE_A", value: "one two"),
                    TmuxEnvironmentVariable(name: "SWIFTPROBE_B", value: ""),
                    TmuxEnvironmentVariable(name: "SWIFTPROBE_C", value: nil),
                    TmuxEnvironmentVariable(name: "SWIFTPROBE_D", value: "a=b;"),
                ]
            )
        }
    }

    @Test(
        "a listing over a connection reads the same variables",
        .enabled(if: laneSupportsControl, "control mode needs tmux 3.7"))
    func listingOverAConnection() async throws {
        try await withTmuxServer { server in
            _ = try await server.setEnvironment("SWIFTPROBE_A", to: "one \"two\" $three")
            _ = try await server.removeEnvironment("SWIFTPROBE_C")

            let listed = try await server.using(.connected(to: "bootstrap")) { server in
                try await server.environment().filter { $0.name.hasPrefix("SWIFTPROBE_") }
            }
            #expect(
                listed == [
                    TmuxEnvironmentVariable(name: "SWIFTPROBE_A", value: "one \"two\" $three"),
                    TmuxEnvironmentVariable(name: "SWIFTPROBE_C", value: nil),
                ]
            )
        }
    }
}
