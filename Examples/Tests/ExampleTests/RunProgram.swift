import Foundation

/// What a child program printed and how it ended.
struct ProgramResult {
    let status: Int32
    let output: String
}

struct ProgramTimedOut: Error, CustomStringConvertible {
    let limit: Duration
    var description: String { "the program was still running after \(limit)" }
}

/// Reads what is in `descriptor` now, without waiting for more.
///
/// The child has exited by the time this runs, so what it wrote is already in
/// the pipe. Asking for "to the end" would wait for every holder of the write
/// end to close, and a descendant that outlived the child holds it.
private func drain(_ descriptor: Int32) -> String {
    let flags = fcntl(descriptor, F_GETFL)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count <= 0 { break }
        collected.append(contentsOf: buffer[0..<count])
    }
    return String(decoding: collected, as: UTF8.self)
}

/// Runs `process` and returns its output, or throws `ProgramTimedOut` after
/// `limit`. Resumes from `terminationHandler` because `waitUntilExit()` can park
/// the thread on macOS, where a time limit cannot cancel it. Output is read
/// after the exit, without waiting for EOF.
func runProgram(
    _ process: Process,
    within limit: Duration = .seconds(60)
) async throws -> ProgramResult {
    let output = Pipe()
    process.standardOutput = output
    let (exited, signal) = AsyncStream.makeStream(of: Void.self)
    process.terminationHandler = { _ in
        signal.yield()
        signal.finish()
    }
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in exited { return true }
            return false
        }
        group.addTask {
            try await Task.sleep(for: limit)
            return false
        }
        let first = try await group.next() ?? false
        group.cancelAll()
        return first
    }
    guard finished else { throw ProgramTimedOut(limit: limit) }
    return ProgramResult(
        status: process.terminationStatus,
        output: drain(output.fileHandleForReading.fileDescriptor)
    )
}
