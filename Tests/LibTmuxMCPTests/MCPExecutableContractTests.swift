import Foundation
import Subprocess
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("MCP executable contract", .hangLimit)
struct MCPExecutableContractTests {
    @Test("--help and --version answer without serving a socket; unknown argv is refused")
    func argvIsNotIgnored() async throws {
        let binary = executableURL
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))
        // No LIBTMUX_* environment at all: if any of these paths reached
        // configuration and tried to serve, it would need a socket this test
        // never named.
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("LIBTMUX_") {
            environment.removeValue(forKey: key)
        }

        let help = try await run(binary, arguments: ["--help"], environment: environment)
        #expect(help.status == 0)
        #expect(help.stdout.contains("Usage: libtmux-mcp"))

        let version = try await run(binary, arguments: ["--version"], environment: environment)
        #expect(version.status == 0)
        #expect(version.stdout.contains("libtmux-mcp"))

        let unknown = try await run(
            binary, arguments: ["--not-a-real-flag"], environment: environment)
        #expect(unknown.status != 0)
        #expect(unknown.stderr.contains("--not-a-real-flag"))
    }

    private func run(
        _ binary: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        let reply = try await withCommandDeadline(.seconds(1)) {
            try await SubprocessTransport().run(
                executable: binary.path, arguments: arguments, environment: environment,
                perStreamOutputLimit: 65_536)
        }
        return (reply.exitCode, reply.text, reply.errorText)
    }

    @Test("the executable refuses partial caller context before pane input")
    func executableRefusesPartialCallerContext() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let session = try #require(try await server.sessions().first)
            let incarnation = try await server.incarnation()
            let marker = "partial-caller-must-not-dispatch"

            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys where key.hasPrefix("LIBTMUX_") {
                environment.removeValue(forKey: key)
            }
            // Clearing the prefix takes the lane's tmux with it, and a client
            // whose protocol version differs from the server's is refused with
            // `server exited unexpectedly`. Naming it again is what keeps this
            // case measuring the release the matrix selected rather than
            // whichever tmux the runner happens to ship.
            environment["LIBTMUX_TMUX_BIN"] = tmuxExecutablePath()
            environment["LIBTMUX_SOCKET_PATH"] = incarnation.socketPath
            environment["LIBTMUX_TOOLSETS"] = "execute"
            environment["TMUX"] =
                "\(incarnation.socketPath),\(incarnation.processID),"
                + session.id.rawValue.dropFirst()
            environment.removeValue(forKey: "TMUX_PANE")
            let request =
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_keys","arguments":{"keys":["\#(marker)"],"literal":true,"paneId":"\#(pane.id.rawValue)"}}}"#
            let reply = try await exchange(request, environment: environment)
            #expect(reply.contains("caller context is incomplete or malformed"))
            #expect(try await server.capture(pane).contains(marker) == false)
        }
    }

    @Test("the shipped executable answers over stdio while input stays open")
    func executableAnswersOverStdio() async throws {
        let binary = executableURL
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))

        var environment = ProcessInfo.processInfo.environment
        environment["LIBTMUX_SOCKET_PATH"] = "/tmp/libtmux-swift-test/stdio-unstarted"
        environment["LIBTMUX_TOOLSETS"] = ""
        environment.removeValue(forKey: "LIBTMUX_SAFETY")
        let line = try await exchange(
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, environment: environment)
        let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(reply?["id"] as? Int == 1)
    }

    @Test("the owned default daemon exits when standard input closes")
    func ownedDefaultDaemonExitsWithInput() async throws {
        let socketDirectory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("mcp-owned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: socketDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: socketDirectory) }

        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("LIBTMUX_") {
            environment.removeValue(forKey: key)
        }
        // The daemon this starts is the one the lane is meant to exercise.
        environment["LIBTMUX_TMUX_BIN"] = tmuxExecutablePath()
        environment["TMUX_TMPDIR"] = socketDirectory.path

        _ = try await exchange(
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, environment: environment)

        let retained =
            try await tmuxStatus(
                ["show-options", "-gqv", "@libtmux_mcp_owner"],
                environment: environment
            ) == 0
        if retained {
            _ = try? await tmuxStatus(["kill-server"], environment: environment)
        }
        #expect(!retained)
    }

    private var executableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/libtmux-mcp")
    }

    private func tmuxStatus(
        _ arguments: [String],
        environment: [String: String]
    ) async throws -> Int32 {
        try await run(
            URL(fileURLWithPath: tmuxExecutablePath()),
            arguments: ["-L", "libtmux-mcp"] + arguments, environment: environment
        ).status
    }

    private func exchange(_ request: String, environment: [String: String]) async throws -> String {
        let binary = executableURL
        return try await withCommandDeadline(.seconds(1)) {
            var options = PlatformOptions()
            options.processGroupID = 0
            options.teardownSequence = [
                .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)
            ]
            let result = try await Subprocess.run(
                .path(.init(binary.path)),
                environment: .custom(
                    environment.reduce(into: [:]) { values, entry in
                        values[Subprocess.Environment.Key(rawValue: entry.key)!] = entry.value
                    }),
                platformOptions: options,
                input: .inputWriter, output: .sequence, error: .string(limit: 65_536)
            ) { execution in
                try await execution.standardInputWriter.write(Array((request + "\n").utf8))
                var bytes: [UInt8] = []
                var response: String?
                for try await chunk in execution.standardOutput {
                    chunk.withUnsafeBytes { bytes.append(contentsOf: $0) }
                    try #require(bytes.count <= 65_536)
                    while let newline = bytes.firstIndex(of: 10) {
                        let line = String(decoding: bytes[..<newline], as: UTF8.self)
                        bytes.removeSubrange(...newline)
                        if let response {
                            let ping =
                                try JSONSerialization.jsonObject(with: Data(line.utf8))
                                as? [String: Any]
                            try #require(ping?["id"] as? Int == 2)
                            try await execution.standardInputWriter.finish()
                            return response
                        }
                        response = line
                        try await execution.standardInputWriter.write(
                            Array((#"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n").utf8))
                    }
                }
                throw TmuxError.invocationFailed(reason: "MCP exited without a response")
            }
            #expect(result.terminationStatus == .exited(0), Comment(rawValue: result.standardError))
            return result.closureResult
        }
    }
}
