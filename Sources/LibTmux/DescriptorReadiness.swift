import Dispatch
import Foundation

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
        await withTaskCancellationHandler {
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
