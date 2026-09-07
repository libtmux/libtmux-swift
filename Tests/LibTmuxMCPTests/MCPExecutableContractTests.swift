import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("MCP executable contract", .timeLimit(.minutes(1)))
struct MCPExecutableContractTests {
    @Test("the executable refuses partial caller context before pane input")
    func executableRefusesPartialCallerContext() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let session = try #require(try await server.sessions().first)
            let incarnation = try await server.incarnation()
            let marker = "partial-caller-must-not-dispatch"

            let input = Pipe()
            let output = Pipe()
            let process = Process()
            process.executableURL = executableURL
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
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
            process.environment = environment
            try process.run()
            defer {
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }

            let request =
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"send_keys","arguments":{"keys":["\#(marker)"],"literal":true,"paneId":"\#(pane.id.rawValue)"}}}"#
            try input.fileHandleForWriting.write(contentsOf: Data(request.utf8 + [10]))
            let reply = try #require(
                readLine(from: output.fileHandleForReading, within: .seconds(3)))
            #expect(reply.contains("caller context is incomplete or malformed"))
            #expect(try await server.capture(pane).contains(marker) == false)
        }
    }

    @Test("the shipped executable answers over stdio while input stays open")
    func executableAnswersOverStdio() throws {
        let binary = executableURL
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))

        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = binary
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["LIBTMUX_SOCKET_PATH"] = "/tmp/libtmux-swift-test/stdio-unstarted"
        environment["LIBTMUX_TOOLSETS"] = ""
        environment.removeValue(forKey: "LIBTMUX_SAFETY")
        process.environment = environment
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        try input.fileHandleForWriting.write(
            contentsOf: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8 + [10])
        )
        let line = try #require(readLine(from: output.fileHandleForReading, within: .seconds(3)))
        let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        #expect(reply?["id"] as? Int == 1)
        #expect(process.isRunning)
    }

    @Test("the owned default daemon exits when standard input closes")
    func ownedDefaultDaemonExitsWithInput() throws {
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

        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        process.environment = environment
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        try input.fileHandleForWriting.write(
            contentsOf: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8 + [10])
        )
        _ = try #require(readLine(from: output.fileHandleForReading, within: .seconds(3)))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let retained =
            try tmuxStatus(
                ["show-options", "-gqv", "@libtmux_mcp_owner"],
                environment: environment
            ) == 0
        if retained {
            _ = try? tmuxStatus(["kill-server"], environment: environment)
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
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "-L", "libtmux-mcp"] + arguments
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func readLine(from handle: FileHandle, within duration: Duration) -> String? {
        var data = Data()
        while true {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let timeout =
                duration.components.seconds * 1_000
                + duration.components.attoseconds / 1_000_000_000_000_000
            guard poll(&descriptor, 1, Int32(timeout)) > 0 else { return nil }
            let byte = handle.readData(ofLength: 1)
            guard let value = byte.first else {
                return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
            }
            if value == 10 { return String(decoding: data, as: UTF8.self) }
            data.append(value)
        }
    }
}
