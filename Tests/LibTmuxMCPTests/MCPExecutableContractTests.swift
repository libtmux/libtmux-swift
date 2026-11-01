import Foundation
import Testing

@testable import LibTmux
@testable import TmuxFixture

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
            var environment = sandboxedEnvironment()
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
            // The partial context under test, on the fixture's own server: `TMUX`
            // with no `TMUX_PANE`. Nothing else reaches the child from outside.
            environment["TMUX"] =
                "\(incarnation.socketPath),\(incarnation.processID),"
                + session.id.rawValue.dropFirst()
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
        var environment = sandboxedEnvironment()
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

    @Test("with no socket named the executable starts no server of its own")
    func noSocketStartsNoServer() throws {
        try withScratchDirectory { directory in
            let reply = try serveCapabilities(in: directory, tmux: nil)
            #expect(reply.connection["socketProvenance"] == "tmux-choice")
            #expect(reply.connection["serverState"] == "absent")
            #expect(reply.connection["resolvedSocketPath"] == "")
            #expect(
                reply.connection["attachCommand"]?.hasSuffix(" -N attach") == true,
                "the attach command names a socket although no server runs")
            // tmux makes its socket directory for a client that only looks, so
            // the directory is no evidence. A socket in it is: the dedicated
            // `libtmux-mcp` server this replaces would have left one there.
            let sockets = try FileManager.default.contentsOfDirectory(
                atPath: directory.appendingPathComponent("tmux-\(getuid())").path)
            #expect(
                sockets.isEmpty, "the executable started a server on \(sockets.count) socket(s)")
        }
    }

    @Test("with no socket named, inside tmux, the executable serves the server TMUX names")
    func noSocketFollowsTmux() async throws {
        try await withTmuxServer { surrounding in
            let incarnation = try await surrounding.incarnation()
            try withScratchDirectory { directory in
                let pane = "\(incarnation.socketPath),\(incarnation.processID),0"
                let reply = try serveCapabilities(in: directory, tmux: pane)
                #expect(reply.connection["socketProvenance"] == "tmux-choice")
                #expect(reply.connection["socketSelector"] == "tmux-choice")
                #expect(reply.connection["serverState"] == "existing")
                #expect(reply.connection["resolvedSocketPath"] == incarnation.socketPath)
                #expect(
                    reply.connection["attachCommand"]?.hasSuffix(
                        " -N -S '\(incarnation.socketPath)' attach") == true,
                    "the attach command does not name the socket the server reached")
            }
        }
    }

    @Test("a socket variable beats the TMUX server, and the path beats the name")
    func variablesBeatTmux() async throws {
        try await withTmuxServer { surrounding in
            try await withTmuxServer(socketFileName: "chosen") { chosen in
                let surroundingIncarnation = try await surrounding.incarnation()
                let chosenIncarnation = try await chosen.incarnation()
                let pane =
                    "\(surroundingIncarnation.socketPath),\(surroundingIncarnation.processID),0"
                try withScratchDirectory { directory in
                    let byPath = try serveCapabilities(
                        in: directory, tmux: pane,
                        variables: [
                            "LIBTMUX_SOCKET_PATH": chosenIncarnation.socketPath,
                            "LIBTMUX_SOCKET": "libtmux-swift-ignored",
                        ])
                    #expect(byPath.connection["socketProvenance"] == "socket-path")
                    #expect(byPath.connection["resolvedSocketPath"] == chosenIncarnation.socketPath)
                    let byName = try serveCapabilities(
                        in: directory, tmux: pane,
                        variables: ["LIBTMUX_SOCKET": "libtmux-swift-unstarted"])
                    #expect(byName.connection["socketProvenance"] == "socket-name")
                    #expect(byName.connection["serverState"] == "absent")
                }
            }
        }
    }

    /// What `tmux://capabilities` reports once the executable has started.
    private struct CapabilityReply {
        let connection: [String: String]
    }

    /// Starts the executable as a process in a pane would, reads the capability
    /// resource, and closes its input. `tmux` is the `TMUX` the pane has;
    /// `variables` are the socket variables it was launched with.
    private func serveCapabilities(
        in directory: URL, tmux: String?, variables: [String: String] = [:]
    ) throws -> CapabilityReply {
        var environment = sandboxedEnvironment(tmuxTemporaryDirectory: directory.path)
        for key in environment.keys where key.hasPrefix("LIBTMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["LIBTMUX_TMUX_BIN"] = tmuxExecutablePath()
        environment["LIBTMUX_TOOLSETS"] = ""
        environment.merge(variables) { _, new in new }
        if let tmux { environment["TMUX"] = tmux }

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
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        try input.fileHandleForWriting.write(
            contentsOf: Data(
                #"{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"tmux://capabilities"}}"#
                    .utf8 + [10]))
        let line = try #require(readLine(from: output.fileHandleForReading, within: .seconds(10)))
        let reply = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let contents = (reply?["result"] as? [String: Any])?["contents"] as? [[String: Any]]
        let text = try #require(contents?.first?["text"] as? String)
        let report = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let connection = try #require(report?["connection"] as? [String: Any])
        return CapabilityReply(connection: connection.compactMapValues { $0 as? String })
    }

    private func withScratchDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("mcp-socket-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private var executableURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/libtmux-mcp")
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
