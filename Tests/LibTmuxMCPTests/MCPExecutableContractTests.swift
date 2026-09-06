import Foundation
import Testing

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("MCP executable contract", .timeLimit(.minutes(1)))
struct MCPExecutableContractTests {
    @Test("the shipped executable answers over stdio while input stays open")
    func executableAnswersOverStdio() throws {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/libtmux-mcp")
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
