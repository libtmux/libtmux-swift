import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("MCP executable")
struct MCPExecutableTests {
    @Test("the executable responds with nonblocking output while input remains open")
    func executableReadsAvailableInput() throws {
        let (process, input, output, outputFlagsDescriptor) = try launchExecutable()
        defer {
            _ = close(outputFlagsDescriptor)
            stop(process, input: input)
        }

        try writePing(1, to: input)
        let first = try #require(
            readLine(from: output.fileHandleForReading, within: .seconds(1))
        )
        #expect(first.contains(#""id":1"#))
        let flags = fcntl(outputFlagsDescriptor, F_GETFL)
        try #require(flags >= 0)
        #expect(flags & O_NONBLOCK != 0)
    }

    @Test("the executable survives a broken pipe signal")
    func executableIgnoresSIGPIPE() async throws {
        let (process, input, output, outputFlagsDescriptor) = try launchExecutable()
        defer {
            _ = close(outputFlagsDescriptor)
            stop(process, input: input)
        }

        try writePing(1, to: input)
        _ = try #require(
            readLine(from: output.fileHandleForReading, within: .seconds(1))
        )

        #expect(kill(process.processIdentifier, SIGPIPE) == 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(process.isRunning)
        guard process.isRunning else { return }

        try writePing(2, to: input)
        let second = try #require(
            readLine(from: output.fileHandleForReading, within: .seconds(1))
        )
        #expect(second.contains(#""id":2"#))
    }

    @Test("the executable exits when standard output closes")
    func executableExitsAfterOutputCloses() async throws {
        let (process, input, output, outputFlagsDescriptor) = try launchExecutable()
        defer {
            _ = close(outputFlagsDescriptor)
            stop(process, input: input)
        }

        try output.fileHandleForReading.close()
        try writePing(1, to: input)
        for _ in 0..<100 where process.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        guard !process.isRunning else {
            Issue.record("the executable kept serving after its output closed")
            return
        }
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    private func launchExecutable() throws -> (Process, Pipe, Pipe, Int32) {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/libtmux-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))

        let input = Pipe()
        let output = Pipe()
        let outputFlagsDescriptor = dup(output.fileHandleForWriting.fileDescriptor)
        try #require(outputFlagsDescriptor >= 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap - PIPE; exec \"$1\"", "sh", binary.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["LIBTMUX_SOCKET_PATH"] = "/tmp/libtmux-swift-test/stdio-unstarted"
        process.environment = environment
        do {
            try process.run()
        } catch {
            _ = close(outputFlagsDescriptor)
            throw error
        }
        return (process, input, output, outputFlagsDescriptor)
    }

    private func stop(_ process: Process, input: Pipe) {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func writePing(_ identifier: Int, to input: Pipe) throws {
        try input.fileHandleForWriting.write(
            contentsOf: Data(
                #"{"jsonrpc":"2.0","id":\#(identifier),"method":"ping"}"#.utf8 + [10]
            )
        )
    }

    private func readLine(
        from handle: FileHandle,
        within duration: Duration
    ) -> String? {
        var data = Data()
        while true {
            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
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
