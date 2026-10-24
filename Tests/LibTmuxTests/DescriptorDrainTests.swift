import Foundation
import Testing
import TmuxFixture

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A drained descriptor must be released before its number is reused.
///
/// The attached-client case drains a pseudo-terminal on a thread and closes it
/// afterwards. A reader still looping at that point reads the next file the
/// process puts under the same number, which in this suite is a pipe carrying
/// another case's tmux reply.
///
/// Serialized because the cases reason about descriptor numbers, which every
/// case in the process shares.
@Suite("descriptor drain", .serialized, .timeLimit(.minutes(1)))
struct DescriptorDrainTests {
    @Test("a closed descriptor's number is never read by a leftover reader")
    func reusedDescriptorKeepsItsBytes() throws {
        signal(SIGPIPE, SIG_IGN)
        let marker = Array("kept\n".utf8)
        var stolen = 0
        for _ in 0..<300 {
            var busy: [Int32] = [-1, -1]
            try #require(pipe(&busy) == 0)
            let feeding = Feeder(descriptor: busy[1])
            let drain = DescriptorDrain(reading: busy[0])
            usleep(500)

            drain.stop()
            close(busy[0])

            // Another case's pipe, which the process opens under the number the
            // drained one just gave up, with its bytes already waiting.
            var next: [Int32] = [-1, -1]
            try #require(pipe(&next) == 0)
            try #require(write(next[1], marker, marker.count) == marker.count)
            usleep(300)

            var buffer = [UInt8](repeating: 0, count: marker.count)
            let flags = fcntl(next[0], F_GETFL)
            _ = fcntl(next[0], F_SETFL, flags | O_NONBLOCK)
            if read(next[0], &buffer, buffer.count) != marker.count || buffer != marker {
                stolen += 1
            }
            feeding.stop()
            close(busy[1])
            close(next[0])
            close(next[1])
        }
        #expect(stolen == 0, "a reader consumed the bytes of a pipe it was never given")
    }

    @Test("stopping returns once the other end has already closed")
    func stopAfterHangup() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        let drain = DescriptorDrain(reading: ends[0])
        close(ends[1])
        usleep(10_000)
        drain.stop()
        close(ends[0])
    }
}

/// Keeps a pipe's reader supplied, as a client redrawing its screen does.
private final class Feeder: @unchecked Sendable {
    private let lock = NSLock()
    private var halted = false
    private let finished = DispatchSemaphore(value: 0)

    init(descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        Thread.detachNewThread { [self] in
            let chunk = [UInt8](repeating: 0x61, count: 512)
            while !isHalted { _ = write(descriptor, chunk, chunk.count) }
            finished.signal()
        }
    }

    func stop() {
        lock.lock()
        halted = true
        lock.unlock()
        finished.wait()
    }

    private var isHalted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return halted
    }
}
