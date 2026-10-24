import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Reads a descriptor until it is told to stop, and proves it has stopped before
/// the descriptor can be closed.
///
/// Draining a pseudo-terminal keeps its client from blocking on a full buffer.
/// A reader that loops on `read(descriptor)` while another thread closes the
/// descriptor does not stop: its next call lands on whatever the process
/// opened next under the same number, and it consumes that file's bytes. In a
/// suite that spawns tmux servers concurrently, the number is soon a pipe
/// carrying another case's reply, so a listing arrives short or a command's
/// marker line never arrives, in a case that has nothing to do with this one.
///
/// ``stop()`` returns only after the reader has left its loop, so the caller can
/// close the descriptor afterwards without a reader outliving it.
public final class DescriptorDrain: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var requested = false
    private let finished = DispatchSemaphore(value: 0)

    /// Starts reading `descriptor`, which the caller keeps open until ``stop()``
    /// has returned. The descriptor is made non-blocking so the reader can
    /// notice a stop request instead of sitting in `read` through it.
    public init(reading descriptor: Int32) {
        self.descriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        Thread.detachNewThread { [self] in
            run()
            finished.signal()
        }
    }

    /// Stops the reader and waits until it has exited. Safe to call once.
    public func stop() {
        lock.lock()
        requested = true
        lock.unlock()
        finished.wait()
    }

    private var stopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !stopRequested {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { continue }
            // Nothing to read yet; look again shortly. Anything else is the
            // other end closing, or an error, and there is nothing more to drain.
            guard count < 0, errno == EAGAIN || errno == EINTR else { return }
            usleep(2_000)
        }
    }
}
