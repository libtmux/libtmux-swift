import Dispatch
import Foundation

#if os(Linux)
    import Glibc
#endif

package final class DescriptorReadiness: @unchecked Sendable {
    package enum Interest: Sendable { case read, write }

    private let fileDescriptor: Int32
    private let interest: Interest
    private let lock = NSLock()
    private var source: (any DispatchSourceProtocol)?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolved = false

    package init(fileDescriptor: Int32, interest: Interest) {
        self.fileDescriptor = fileDescriptor
        self.interest = interest
    }

    package func wait() async -> Bool {
        #if os(Linux)
            if interest == .write {
                return await PipeWriteReadiness(fileDescriptor: fileDescriptor).wait()
            }
        #endif
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                self.continuation = continuation
                let source: any DispatchSourceProtocol
                switch interest {
                case .read:
                    source = DispatchSource.makeReadSource(
                        fileDescriptor: fileDescriptor, queue: .global())
                case .write:
                    source = DispatchSource.makeWriteSource(
                        fileDescriptor: fileDescriptor, queue: .global())
                }
                self.source = source
                source.setEventHandler { self.resolve(ready: true) }
                lock.unlock()
                source.resume()
            }
        } onCancel: {
            resolve(ready: false)
        }
    }

    private func resolve(ready: Bool) {
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
        continuation?.resume(returning: ready)
    }
}

#if os(Linux)
    private final class PipeWriteReadiness: @unchecked Sendable {
        private let fileDescriptor: Int32
        private let lock = NSLock()
        private var cancellationDescriptor: Int32?
        private var cancelled = false

        init(fileDescriptor: Int32) { self.fileDescriptor = fileDescriptor }

        func wait() async -> Bool {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if cancelled || Task.isCancelled {
                        lock.unlock()
                        continuation.resume(returning: false)
                        return
                    }
                    var descriptors: [Int32] = [0, 0]
                    let options = Int32(
                        SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue | SOCK_NONBLOCK.rawValue)
                    guard socketpair(AF_UNIX, options, 0, &descriptors) == 0 else {
                        lock.unlock()
                        continuation.resume(returning: false)
                        return
                    }
                    let readDescriptor = descriptors[0]
                    let writeDescriptor = descriptors[1]
                    cancellationDescriptor = writeDescriptor
                    lock.unlock()
                    // Linux Dispatch write sources can miss a full pipe's reader closing.
                    DispatchQueue.global(qos: .utility).async {
                        var watched = [
                            pollfd(fd: self.fileDescriptor, events: Int16(POLLOUT), revents: 0),
                            pollfd(fd: readDescriptor, events: Int16(POLLIN), revents: 0),
                        ]
                        var count: Int32
                        repeat { count = poll(&watched, 2, -1) } while count < 0 && errno == EINTR
                        self.lock.lock()
                        let ready = count > 0 && watched[0].revents != 0 && !self.cancelled
                        self.cancellationDescriptor = nil
                        _ = close(readDescriptor)
                        _ = close(writeDescriptor)
                        self.lock.unlock()
                        continuation.resume(returning: ready)
                    }
                }
            } onCancel: {
                self.lock.lock()
                self.cancelled = true
                if let descriptor = self.cancellationDescriptor {
                    var byte: UInt8 = 1
                    var count: Int
                    repeat { count = write(descriptor, &byte, 1) } while count < 0 && errno == EINTR
                }
                self.lock.unlock()
            }
        }
    }
#endif
