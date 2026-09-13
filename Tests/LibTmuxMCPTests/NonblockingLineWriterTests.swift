import LibTmux
import Testing

@testable import LibTmuxMCP

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("nonblocking line writer", .timeLimit(.minutes(5)))
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

    @Test("a writable descriptor wakes a blocked write")
    func writableDescriptorWakesBlockedWrite() async throws {
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

        let writing = Task { await writer.write("woken") }
        defer { writing.cancel() }
        try await Task.sleep(for: .milliseconds(20))

        var bytes = [UInt8](repeating: 0, count: 4_096)
        let count = bytes.withUnsafeMutableBytes { buffer in
            systemRead(readDescriptor, buffer.baseAddress, buffer.count)
        }
        try #require(count > 0)

        #expect(await completes(writing, within: .milliseconds(200)) == .written)
    }

    @Test("a closed reader wakes a full pipe's write readiness")
    func closedReaderWakesWriteReadiness() async throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        try #require(pipe(&descriptors) == 0)
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer { _ = close(writeDescriptor) }
        _ = try NonblockingLineWriter(fileDescriptor: writeDescriptor)
        try fill(writeDescriptor)
        let writing = Task {
            await DescriptorReadiness(fileDescriptor: writeDescriptor, interest: .write).wait()
                ? LineWriteResult.written : .cancelled
        }
        try await Task.sleep(for: .milliseconds(20))
        _ = close(readDescriptor)
        #expect(await completes(writing, within: .milliseconds(200)) == .written)
    }

    @Test("closing and cancelling repeated waits cannot strand reused descriptors")
    func closeCancellationRaces() async throws {
        for attempt in 0..<100 {
            var descriptors = [Int32](repeating: 0, count: 2)
            try #require(pipe(&descriptors) == 0)
            let readDescriptor = descriptors[0]
            let writeDescriptor = descriptors[1]
            _ = try NonblockingLineWriter(fileDescriptor: writeDescriptor)
            try fill(writeDescriptor)
            let writing = Task {
                if attempt % 3 == 0 { withUnsafeCurrentTask { $0?.cancel() } }
                return await DescriptorReadiness(fileDescriptor: writeDescriptor, interest: .write)
                    .wait()
                    ? LineWriteResult.written : .cancelled
            }
            if attempt % 3 == 1 { await Task.yield() }
            if attempt % 3 == 2 { try await Task.sleep(for: .milliseconds(1)) }
            _ = close(readDescriptor)
            writing.cancel()
            let outcome = await completes(writing, within: .milliseconds(200))
            _ = close(writeDescriptor)
            #expect(outcome == .written || outcome == .cancelled)
        }
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

    private func completes(
        _ task: Task<LineWriteResult, Never>,
        within timeout: Duration
    ) async -> LineWriteResult? {
        await withTaskGroup(of: LineWriteResult?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            if result == nil { task.cancel() }
            group.cancelAll()
            return result
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
