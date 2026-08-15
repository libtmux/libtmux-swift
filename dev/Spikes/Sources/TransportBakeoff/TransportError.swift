import Foundation
import SpikeSupport

#if canImport(Darwin)
    import os
#else
    import Synchronization
#endif

package enum ProcessOutputStream: String, Error, Sendable, Equatable {
    case standardOutput
    case standardError
}

package struct ProcessOutputLimitError: Error, Sendable, Equatable {
    package let stream: ProcessOutputStream
    package let limit: Int

    package init(stream: ProcessOutputStream, limit: Int) {
        self.stream = stream
        self.limit = limit
    }
}

final class OutputLimitArbiter: Sendable {
    private let limit: Int?
    #if canImport(Darwin)
        private let firstOverflow = OSAllocatedUnfairLock<ProcessOutputStream?>(
            initialState: nil
        )
    #else
        private let firstOverflow = Mutex<ProcessOutputStream?>(nil)
    #endif

    init(limit: Int?) {
        self.limit = limit
    }

    var error: ProcessOutputLimitError? {
        firstOverflow.withLock { stream in
            guard let stream, let limit else { return nil }
            return ProcessOutputLimitError(stream: stream, limit: limit)
        }
    }

    func exceeded(on stream: ProcessOutputStream) -> Bool {
        firstOverflow.withLock { firstOverflow in
            guard firstOverflow == nil else { return false }
            firstOverflow = stream
            return true
        }
    }
}

package enum ProcessInvocationError: Error, Sendable, Equatable {
    case executableNotFound(String)
    case invalidWorkingDirectory(String)
    case spawnFailed(code: Int32)
    case ioFailure(operation: String, code: Int32)
    case upstream(String)
}

enum InteractiveInputMessage: Sendable {
    case write(UUID, [UInt8])
    case finish(UUID)
}

package enum InteractiveProcessError: Error, Sendable, Equatable {
    case inputFinished
    case sessionTerminated
    case writeFailed(code: Int32)
}

enum CapturedStream: Sendable {
    case standardOutput([UInt8])
    case standardError([UInt8])
}

/*
 Interactive process groups use a separate lifecycle channel so a blocked stdin
 write cannot prevent termination from reaching the child.
 */
enum InteractiveLifecycleMessage: Sendable {
    case terminate(UUID)
}

enum InteractiveOwnerEvent: Sendable {
    case standardOutputEnded
    case standardErrorEnded
    case inputEnded
    case terminationRequested
    case processTerminated(ProcessTermination)
}

func outputLimit(
    for policy: OutputPolicy
) -> Int? {
    switch policy {
    case .complete:
        nil
    case let .limited(maxBytesPerStream):
        maxBytesPerStream
    }
}
