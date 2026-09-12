import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

package enum NonblockingLineWriterSetupError: Error, Sendable, Equatable {
    case cannotReadFlags(Int32)
    case cannotSetNonblocking(Int32)
}

package enum LineWriteResult: Sendable, Equatable {
    case written
    case closed
    case cancelled
    case failed(Int32)
}

package struct NonblockingLineWriter: Sendable {
    private let fileDescriptor: Int32

    package init(fileDescriptor: Int32) throws(NonblockingLineWriterSetupError) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw .cannotReadFlags(errno)
        }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw .cannotSetNonblocking(errno)
        }
        self.fileDescriptor = fileDescriptor
    }

    package func write(_ line: String) async -> LineWriteResult {
        let bytes = Array("\(line)\n".utf8)
        var offset = 0
        while offset < bytes.count {
            if Task.isCancelled { return .cancelled }
            let count = bytes.withUnsafeBytes { buffer in
                systemWrite(
                    fileDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count > 0 {
                offset += count
                continue
            }
            if count == 0 { return .failed(EIO) }
            let code = errno
            if count < 0, code == EINTR { continue }
            if count < 0, code == EAGAIN || code == EWOULDBLOCK {
                guard await WriteReadiness(fileDescriptor: fileDescriptor).wait() else {
                    return .cancelled
                }
                continue
            }
            if count < 0, code == EPIPE { return .closed }
            return .failed(code)
        }
        return .written
    }
}

private final class WriteReadiness: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let lock = NSLock()
    private var source: DispatchSourceWrite?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved = false

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                let source = DispatchSource.makeWriteSource(
                    fileDescriptor: fileDescriptor,
                    queue: .global()
                )
                self.source = source
                source.setEventHandler { self.resolve(writable: true) }
                lock.unlock()
                source.resume()
            }
        } onCancel: {
            resolve(writable: false)
        }
    }

    private func resolve(writable: Bool) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let source = source
        self.source = nil
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        source?.cancel()
        continuation?.resume(returning: writable)
    }
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
