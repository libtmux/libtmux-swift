import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("MCP executable")
struct MCPExecutableTests {
    @Test("the executable responds while standard input remains open")
    func executableReadsAvailableInput() throws {
        let (process, input, output) = try launchExecutable()
        defer { stop(process, input: input) }

        try writePing(1, to: input)
        let first = try #require(
            readLine(from: output.fileHandleForReading, within: .seconds(1))
        )
        #expect(first.contains(#""id":1"#))
    }

    @Test("the executable survives a broken pipe signal")
    func executableIgnoresSIGPIPE() async throws {
        let (process, input, output) = try launchExecutable()
        defer { stop(process, input: input) }

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

    private func launchExecutable() throws -> (Process, Pipe, Pipe) {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/libtmux-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))

        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap - PIPE; exec \"$1\"", "sh", binary.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["LIBTMUX_SOCKET_PATH"] = "/tmp/libtmux-swift-test/stdio-unstarted"
        process.environment = environment
        try process.run()
        return (process, input, output)
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
