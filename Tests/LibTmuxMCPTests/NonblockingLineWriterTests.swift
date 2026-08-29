import Testing

@testable import LibTmuxMCP

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("nonblocking line writer", .timeLimit(.minutes(1)))
struct NonblockingLineWriterTests {
    @Test("writes one complete protocol line")
    func writesCompleteLine() async throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        try #require(pipe(&descriptors) == 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer {
            _ = close(readDescriptor)
            _ = close(writeDescriptor)
        }

        let writer = try NonblockingLineWriter(fileDescriptor: writeDescriptor)
        #expect(await writer.write("answer") == .written)

        var bytes = [UInt8](repeating: 0, count: 7)
        let count = bytes.withUnsafeMutableBytes { buffer in
            systemRead(readDescriptor, buffer.baseAddress, buffer.count)
        }
        try #require(count >= 0)
        #expect(String(decoding: bytes[..<count], as: UTF8.self) == "answer\n")
    }

    @Test("a full pipe releases a cancelled write")
    func fullPipeReleasesCancelledWrite() async throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        try #require(pipe(&descriptors) == 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer {
            _ = close(readDescriptor)
            _ = close(writeDescriptor)
        }

        let writer = try NonblockingLineWriter(fileDescriptor: writeDescriptor)
        try fill(writeDescriptor)

        let writing = Task { await writer.write("blocked") }
        try await Task.sleep(for: .milliseconds(20))
        writing.cancel()

        #expect(await writing.value == .cancelled)
    }

    private func fill(_ descriptor: Int32) throws {
        let bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = bytes.withUnsafeBytes { buffer in
                systemWrite(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            throw POSIXTestError(operation: "write", code: errno)
        }
    }
}

private struct POSIXTestError: Error {
    let operation: String
    let code: Int32
}

private func systemWrite(
    _ descriptor: Int32,
    _ bytes: UnsafeRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
        Darwin.write(descriptor, bytes, count)
    #else
        Glibc.write(descriptor, bytes, count)
    #endif
}

private func systemRead(
    _ descriptor: Int32,
    _ bytes: UnsafeMutableRawPointer?,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
        Darwin.read(descriptor, bytes, count)
    #else
        Glibc.read(descriptor, bytes, count)
    #endif
}
