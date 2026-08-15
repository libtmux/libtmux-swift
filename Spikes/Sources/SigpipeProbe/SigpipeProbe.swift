import Foundation
import SpikeSupport
import TransportBakeoff

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

private enum SigpipeProbeDeadlineError: Error {
    case exceeded
}

@main
struct SigpipeProbe {
    static func main() async {
        exit(await run())
    }

    private static func run() async -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "closed-stdio", arguments.count == 2 {
            return await runClosedStdio(marker: arguments[1])
        }
        if arguments == ["pending-sigpipe"] {
            return runPendingSIGPIPE()
        }
        if arguments == ["ignored-sigpipe"] {
            return runIgnoredSIGPIPE()
        }
        if arguments == ["foundation-epipe"] {
            return await runFoundationEPIPE()
        }
        if arguments == ["swift-subprocess-epipe"] {
            return await runSwiftSubprocessEPIPE()
        }
        if arguments.count == 5, arguments[0] == "fifo-post-open" {
            guard arguments[4] == "0" || arguments[4] == "1" else { return 64 }
            return runFIFOPostOpen(
                dataPath: arguments[1],
                openedPath: arguments[2],
                continuationPath: arguments[3],
                startsWithPendingSIGPIPE: arguments[4] == "1"
            )
        }
        if arguments.count == 2, arguments[0] == "direct-spawn-default-signal" {
            return await runDirectSpawnDefaultSignal(marker: arguments[1])
        }
        return await runSigpipe(
            processMode: arguments == ["delayed-marker"] ? "delayed-close-input" : "close-input"
        )
    }

    private static func runDirectSpawnDefaultSignal(marker: String) async -> Int32 {
        guard let processProbe = ProcessInfo.processInfo.environment["LIBTMUX_PROCESS_PROBE"]
        else { return 90 }
        _ = signal(SIGTERM, SIG_IGN)
        do {
            let reply = try await withDeadline {
                try await DirectSpawnTransport().run(
                    ProcessRequest(
                        executable: .path(processProbe),
                        arguments: ["raise-inherited-signal", String(SIGTERM), marker],
                        environment: ["LC_ALL": "C"],
                        workingDirectory: nil,
                        outputPolicy: .complete
                    )
                )
            }
            guard reply.standardOutput.isEmpty, reply.standardError.isEmpty,
                reply.termination == .unhandledSignal(SIGTERM)
            else { return 91 }
            return 0
        } catch {
            return 92
        }
    }

    private static func runFoundationEPIPE() async -> Int32 {
        guard let processProbe = ProcessInfo.processInfo.environment["LIBTMUX_PROCESS_PROBE"],
            let markerPath = ProcessInfo.processInfo.environment["LIBTMUX_SIGPIPE_MARKER"]
        else { return 79 }
        do {
            let session = try await FoundationInteractive().launch(
                InteractiveProcessRequest(
                    executable: .path(processProbe),
                    arguments: ["close-input", markerPath],
                    environment: [:],
                    workingDirectory: nil
                )
            )
            async let standardOutput = drain(session.standardOutput)
            async let standardError = drain(session.standardError)
            try await waitForMarker(URL(fileURLWithPath: markerPath))
            do {
                try await session.writeStandardInput([0x61])
                return 80
            } catch let error as InteractiveProcessError {
                guard error == .writeFailed(code: EPIPE) else { return 81 }
            }
            try await session.terminate()
            let termination = try await session.waitForTermination()
            guard case .unhandledSignal = termination else { return 82 }
            _ = try await (standardOutput, standardError)
            return 0
        } catch {
            return 82
        }
    }

    private static func runSwiftSubprocessEPIPE() async -> Int32 {
        guard let processProbe = ProcessInfo.processInfo.environment["LIBTMUX_PROCESS_PROBE"],
            let markerPath = ProcessInfo.processInfo.environment["LIBTMUX_SIGPIPE_MARKER"]
        else { return 83 }
        do {
            let session = try await SwiftSubprocessInteractive().launch(
                InteractiveProcessRequest(
                    executable: .path(processProbe),
                    arguments: ["close-input-stubborn-descendant", markerPath],
                    environment: [:],
                    workingDirectory: nil
                )
            )
            let standardOutput = Task { try await drain(session.standardOutput) }
            let standardError = Task { try await drain(session.standardError) }
            defer {
                standardOutput.cancel()
                standardError.cancel()
            }
            try await waitForMarker(URL(fileURLWithPath: markerPath))

            var result: Int32 = 0
            do {
                try await withDeadline { try await session.writeStandardInput([0x61]) }
                result = 84
            } catch is SigpipeProbeDeadlineError {
                result = 85
            } catch {
            }
            do {
                _ = try await withDeadline { try await session.waitForTermination() }
                result = 86
            } catch is SigpipeProbeDeadlineError {
                result = 87
            } catch {
            }
            do {
                _ = try await withDeadline { try await standardOutput.value }
                _ = try await withDeadline { try await standardError.value }
            } catch {
                result = 88
            }
            if result != 0 {
                try? await session.terminate()
                _ = try? await withDeadline { try await session.waitForTermination() }
            }
            return result
        } catch {
            return 89
        }
    }

    private static func runSigpipe(processMode: String) async -> Int32 {
        guard let processProbe = ProcessInfo.processInfo.environment["LIBTMUX_PROCESS_PROBE"]
        else { return 64 }
        let suppliedMarker = ProcessInfo.processInfo.environment["LIBTMUX_SIGPIPE_MARKER"]
        let marker =
            suppliedMarker.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if suppliedMarker == nil { try? FileManager.default.removeItem(at: marker) }
        }
        do {
            let session = try await DirectSpawnInteractive().launch(
                InteractiveProcessRequest(
                    executable: .path(processProbe),
                    arguments: [processMode, marker.path],
                    environment: [:],
                    workingDirectory: nil
                )
            )
            let standardOutput = Task { try await drain(session.standardOutput) }
            let standardError = Task { try await drain(session.standardError) }
            defer {
                standardOutput.cancel()
                standardError.cancel()
            }
            var result: Int32
            do {
                try await waitForMarker(marker)
                do {
                    try await session.writeStandardInput([0x61])
                    result = 65
                } catch let error as InteractiveProcessError {
                    result = error == .writeFailed(code: EPIPE) ? 0 : 66
                } catch {
                    result = 66
                }
            } catch {
                result = 67
            }

            try? await session.terminate()
            do {
                _ = try await withDeadline { try await session.waitForTermination() }
            } catch let error as InteractiveProcessError {
                if error != .writeFailed(code: EPIPE) { result = 67 }
            } catch {
                result = 67
            }
            do {
                _ = try await withDeadline { try await standardOutput.value }
                _ = try await withDeadline { try await standardError.value }
            } catch {
                result = 67
            }
            return result
        } catch {
            return 67
        }
    }

    private static func runClosedStdio(marker: String) async -> Int32 {
        guard let processProbe = ProcessInfo.processInfo.environment["LIBTMUX_PROCESS_PROBE"]
        else { return 68 }
        _ = close(STDIN_FILENO)
        _ = close(STDOUT_FILENO)
        _ = close(STDERR_FILENO)
        do {
            let payload = "closed ;$(false)\nstdio"
            let reply = try await DirectSpawnTransport().run(
                ProcessRequest(
                    executable: .path(processProbe),
                    arguments: ["argv-marker-stdin", marker, payload],
                    environment: [:],
                    workingDirectory: nil,
                    outputPolicy: .complete
                )
            )
            let expected =
                withUnsafeBytes(of: UInt64(payload.utf8.count).bigEndian, Array.init)
                + payload.utf8
            guard reply.standardOutput == Array(expected), reply.standardError.isEmpty,
                reply.termination == .exited(0)
            else { return 69 }
            return 0
        } catch {
            return 70
        }
    }

    private static func runPendingSIGPIPE() -> Int32 {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { return 71 }
        _ = close(descriptors[0])
        defer { _ = close(descriptors[1]) }

        var signalSet = sigset_t()
        var oldSignalSet = sigset_t()
        sigemptyset(&signalSet)
        sigaddset(&signalSet, SIGPIPE)
        guard pthread_sigmask(SIG_BLOCK, &signalSet, &oldSignalSet) == 0 else { return 72 }
        defer { pthread_sigmask(SIG_SETMASK, &oldSignalSet, nil) }
        guard raise(SIGPIPE) == 0 else { return 73 }

        let writeResult = writePOSIXDescriptorSynchronously(descriptors[1], bytes: [0x61])
        var pendingAfter = sigset_t()
        sigemptyset(&pendingAfter)
        guard sigpending(&pendingAfter) == 0,
            sigismember(&pendingAfter, SIGPIPE) == 1
        else { return 74 }
        var receivedSignal: Int32 = 0
        guard sigwait(&signalSet, &receivedSignal) == 0, receivedSignal == SIGPIPE else {
            return 75
        }
        guard case let .failure(error) = writeResult,
            error as? InteractiveProcessError == .writeFailed(code: EPIPE)
        else { return 76 }
        return 0
    }

    private static func runIgnoredSIGPIPE() -> Int32 {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { return 77 }
        _ = close(descriptors[0])
        defer { _ = close(descriptors[1]) }
        _ = signal(SIGPIPE, SIG_IGN)

        let writeResult = writePOSIXDescriptorSynchronously(descriptors[1], bytes: [0x61])
        guard case let .failure(error) = writeResult,
            error as? InteractiveProcessError == .writeFailed(code: EPIPE)
        else { return 78 }
        return 0
    }

    private static func runFIFOPostOpen(
        dataPath: String,
        openedPath: String,
        continuationPath: String,
        startsWithPendingSIGPIPE: Bool
    ) -> Int32 {
        guard let deadline = synchronousDeadline(afterSeconds: 2),
            let dataIdentity = authenticatedFIFOIdentity(at: dataPath),
            let openedIdentity = authenticatedFIFOIdentity(at: openedPath),
            let continuationIdentity = authenticatedFIFOIdentity(at: continuationPath)
        else { return 93 }

        let dataWriter = openAuthenticatedFIFO(
            at: dataPath,
            flags: O_WRONLY,
            identity: dataIdentity,
            deadline: deadline
        )
        guard dataWriter >= 0 else { return 94 }
        defer { _ = close(dataWriter) }

        let continuationReader = openAuthenticatedFIFO(
            at: continuationPath,
            flags: O_RDONLY,
            identity: continuationIdentity,
            deadline: deadline
        )
        guard continuationReader >= 0 else { return 95 }
        defer { _ = close(continuationReader) }

        _ = signal(SIGPIPE, SIG_DFL)
        var blockedSignals = sigset_t()
        var oldSignalMask = sigset_t()
        guard sigemptyset(&blockedSignals) == 0,
            sigaddset(&blockedSignals, SIGPIPE) == 0,
            sigaddset(&blockedSignals, SIGUSR1) == 0,
            pthread_sigmask(SIG_BLOCK, &blockedSignals, &oldSignalMask) == 0
        else { return 96 }
        defer {
            drainPendingSIGPIPE()
            _ = pthread_sigmask(SIG_SETMASK, &oldSignalMask, nil)
        }
        guard !startsWithPendingSIGPIPE || raise(SIGPIPE) == 0 else { return 97 }

        guard let before = signalSnapshot(),
            before.pendingSIGPIPE == (startsWithPendingSIGPIPE ? 1 : 0),
            before.sigpipeBlocked == 1,
            before.sentinelBlocked == 1
        else { return 98 }

        let openedWriter = openAuthenticatedFIFO(
            at: openedPath,
            flags: O_WRONLY,
            identity: openedIdentity,
            deadline: deadline
        )
        guard openedWriter >= 0 else { return 99 }
        let openedResult = writePOSIXDescriptorSynchronously(openedWriter, bytes: [0x0A])
        _ = close(openedWriter)
        guard case .success = openedResult else { return 100 }
        guard readProbeByte(continuationReader, deadline: deadline) == 0 else { return 101 }

        // A concurrently forked process transiently duplicates every open
        // descriptor, including the reader this release already closed, so the
        // first write can land in the pipe instead of reporting EPIPE.
        var writeResult = writePOSIXDescriptorSynchronously(dataWriter, bytes: [0x0A])
        while case .success = writeResult, !synchronousDeadlineExpired(deadline) {
            writeResult = writePOSIXDescriptorSynchronously(dataWriter, bytes: [0x0A])
        }
        guard case let .failure(error) = writeResult,
            error as? InteractiveProcessError == .writeFailed(code: EPIPE),
            let after = signalSnapshot(),
            after.pendingSIGPIPE == before.pendingSIGPIPE,
            after.sigpipeBlocked == before.sigpipeBlocked,
            after.sentinelBlocked == before.sentinelBlocked
        else { return 102 }

        let record =
            "result=EPIPE pending_before=\(before.pendingSIGPIPE) "
            + "pending_after=\(after.pendingSIGPIPE) "
            + "sigpipe_mask_before=\(before.sigpipeBlocked) "
            + "sigpipe_mask_after=\(after.sigpipeBlocked) "
            + "sentinel_mask_before=\(before.sentinelBlocked) "
            + "sentinel_mask_after=\(after.sentinelBlocked)\n"
        guard
            case .success = writePOSIXDescriptorSynchronously(
                STDOUT_FILENO,
                bytes: Array(record.utf8)
            )
        else { return 103 }
        return 0
    }

    private struct FIFOIdentity {
        let device: dev_t
        let inode: ino_t
    }

    private struct SignalSnapshot {
        let pendingSIGPIPE: Int32
        let sigpipeBlocked: Int32
        let sentinelBlocked: Int32
    }

    private static func authenticatedFIFOIdentity(at path: String) -> FIFOIdentity? {
        guard path.hasPrefix("/"),
            URL(fileURLWithPath: path).standardizedFileURL.path == path
        else { return nil }
        var status = stat()
        guard lstat(path, &status) == 0,
            UInt32(status.st_mode) & 0o170000 == 0o010000,
            status.st_uid == geteuid(),
            UInt32(status.st_mode) & 0o022 == 0
        else { return nil }
        return FIFOIdentity(device: status.st_dev, inode: status.st_ino)
    }

    private static func openAuthenticatedFIFO(
        at path: String,
        flags: Int32,
        identity: FIFOIdentity,
        deadline: UInt64
    ) -> Int32 {
        while !synchronousDeadlineExpired(deadline) {
            errno = 0
            let descriptor = open(path, flags | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            if descriptor >= 0 {
                var status = stat()
                guard fstat(descriptor, &status) == 0,
                    UInt32(status.st_mode) & 0o170000 == 0o010000,
                    status.st_dev == identity.device,
                    status.st_ino == identity.inode
                else {
                    _ = close(descriptor)
                    return -1
                }
                return descriptor
            }
            guard errno == ENXIO || errno == EINTR else { return -1 }
            pauseSynchronousProbe()
        }
        return -1
    }

    private static func readProbeByte(_ descriptor: Int32, deadline: UInt64) -> Int32 {
        var byte: UInt8 = 0
        while !synchronousDeadlineExpired(deadline) {
            errno = 0
            let count = read(descriptor, &byte, 1)
            if count == 1 { return 0 }
            guard count == 0 || errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
            else { return errno }
            pauseSynchronousProbe()
        }
        return ETIMEDOUT
    }

    private static func signalSnapshot() -> SignalSnapshot? {
        var signalMask = sigset_t()
        var pending = sigset_t()
        guard pthread_sigmask(SIG_BLOCK, nil, &signalMask) == 0,
            sigemptyset(&pending) == 0,
            sigpending(&pending) == 0
        else { return nil }
        return SignalSnapshot(
            pendingSIGPIPE: sigismember(&pending, SIGPIPE),
            sigpipeBlocked: sigismember(&signalMask, SIGPIPE),
            sentinelBlocked: sigismember(&signalMask, SIGUSR1)
        )
    }

    private static func drainPendingSIGPIPE() {
        var pending = sigset_t()
        var sigpipe = sigset_t()
        guard sigemptyset(&pending) == 0,
            sigpending(&pending) == 0,
            sigismember(&pending, SIGPIPE) == 1,
            sigemptyset(&sigpipe) == 0,
            sigaddset(&sigpipe, SIGPIPE) == 0
        else { return }
        var receivedSignal: Int32 = 0
        _ = sigwait(&sigpipe, &receivedSignal)
    }

    private static func synchronousDeadline(afterSeconds seconds: UInt64) -> UInt64? {
        guard let now = monotonicNanoseconds() else { return nil }
        return now + seconds * 1_000_000_000
    }

    private static func synchronousDeadlineExpired(_ deadline: UInt64) -> Bool {
        guard let now = monotonicNanoseconds() else { return true }
        return now >= deadline
    }

    private static func monotonicNanoseconds() -> UInt64? {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &value) == 0,
            value.tv_sec >= 0,
            value.tv_nsec >= 0
        else { return nil }
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private static func pauseSynchronousProbe() {
        var requested = timespec(tv_sec: 0, tv_nsec: 1_000_000)
        while true {
            var remaining = timespec()
            guard nanosleep(&requested, &remaining) != 0, errno == EINTR else { return }
            requested = remaining
        }
    }

    private static func waitForMarker(_ marker: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: marker), !data.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw InteractiveProcessError.sessionTerminated
    }

    private static func drain(
        _ stream: AsyncThrowingStream<[UInt8], any Error>
    ) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        for try await chunk in stream { bytes.append(contentsOf: chunk) }
        return bytes
    }

    private static func withDeadline<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw SigpipeProbeDeadlineError.exceeded
            }
            guard let value = try await group.next() else {
                throw SigpipeProbeDeadlineError.exceeded
            }
            group.cancelAll()
            return value
        }
    }
}
