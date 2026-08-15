import Foundation
import Testing

@testable import SpikeSupport
@testable import TransportBakeoff

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum TransportKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case swiftSubprocess
    case foundation
    case directSpawn

    var testDescription: String { rawValue }

    func transport() -> any ProcessTransport {
        switch self {
        case .swiftSubprocess:
            SwiftSubprocessTransport()
        case .foundation:
            FoundationProcessTransport()
        case .directSpawn:
            DirectSpawnTransport()
        }
    }

    func launcher() -> any InteractiveProcessLauncher {
        switch self {
        case .swiftSubprocess:
            SwiftSubprocessInteractive()
        case .foundation:
            FoundationInteractive()
        case .directSpawn:
            DirectSpawnInteractive()
        }
    }

    func launcher(
        postSpawnCheckpoint: @escaping @Sendable () async throws -> Void
    ) -> any InteractiveProcessLauncher {
        switch self {
        case .swiftSubprocess:
            SwiftSubprocessInteractive(postSpawnCheckpoint: postSpawnCheckpoint)
        case .foundation:
            FoundationInteractive(postSpawnCheckpoint: postSpawnCheckpoint)
        case .directSpawn:
            DirectSpawnInteractive(postSpawnCheckpoint: postSpawnCheckpoint)
        }
    }
}

struct InteractiveLaunchCancellationCase: Sendable, CustomTestStringConvertible {
    let kind: TransportKind
    let mode: String

    var testDescription: String { "\(kind.rawValue)-\(mode)" }
}

let interactiveLaunchCancellationCases = [
    InteractiveLaunchCancellationCase(kind: .swiftSubprocess, mode: "close-input"),
    InteractiveLaunchCancellationCase(kind: .foundation, mode: "close-input"),
    InteractiveLaunchCancellationCase(kind: .directSpawn, mode: "close-input"),
    InteractiveLaunchCancellationCase(kind: .swiftSubprocess, mode: "block"),
    InteractiveLaunchCancellationCase(kind: .directSpawn, mode: "block"),
]

enum ContractFixtureError: Error {
    case missingProcessProbe
    case invalidProbeReply
}

private func spawnWithBlockedSignal(
    _ signalNumber: Int32,
    request: ProcessRequest
) throws -> SpawnedPOSIXProcess {
    var signalSet = sigset_t()
    var oldSignalSet = sigset_t()
    guard sigemptyset(&signalSet) == 0,
        sigaddset(&signalSet, signalNumber) == 0
    else {
        throw ProcessInvocationError.ioFailure(
            operation: "prepare-test-signal-mask",
            code: errno
        )
    }
    let result = pthread_sigmask(SIG_BLOCK, &signalSet, &oldSignalSet)
    guard result == 0 else {
        throw ProcessInvocationError.ioFailure(
            operation: "block-test-signal",
            code: result
        )
    }
    defer { _ = pthread_sigmask(SIG_SETMASK, &oldSignalSet, nil) }
    return try spawnPOSIX(request: request, interactive: false)
}

private func collectSpawnedPOSIXReply(
    _ process: SpawnedPOSIXProcess,
    owner: POSIXProcessOwner
) async throws -> ProcessReply {
    try await withTaskCancellationHandler {
        let arbiter = OutputLimitArbiter(limit: nil)
        async let standardOutput = readPOSIXDescriptor(
            process.standardOutput,
            stream: .standardOutput,
            limit: nil,
            processGroup: process.processIdentifier,
            arbiter: arbiter,
            processOwner: owner
        )
        async let standardError = readPOSIXDescriptor(
            process.standardError,
            stream: .standardError,
            limit: nil,
            processGroup: process.processIdentifier,
            arbiter: arbiter,
            processOwner: owner
        )
        async let termination = owner.waitForTermination()
        let (output, error, status) = try await (
            standardOutput,
            standardError,
            termination
        )
        return ProcessReply(
            standardOutput: output.bytes,
            standardError: error.bytes,
            termination: status
        )
    } onCancel: {
        owner.signalProcessGroup(SIGKILL)
    }
}

enum InjectedInteractiveTestBodyError: Error, Equatable {
    case sentinel
}

private enum InjectedPipeFailure: Error {
    case exhausted
}

private let outputRampByteCounts: [Int] = {
    if let rawValue = ProcessInfo.processInfo.environment["LIBTMUX_OUTPUT_RAMP_BYTES"],
        let byteCount = Int(rawValue), byteCount > 0, byteCount.isMultiple(of: 256)
    {
        return [byteCount]
    }
    return [256 * 1024, 4 * 1024 * 1024, 32 * 1024 * 1024]
}()

func processProbePath() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["LIBTMUX_PROCESS_PROBE"],
        path.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: path)
    else {
        throw ContractFixtureError.missingProcessProbe
    }
    return path
}

func sacrificialProbePath() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["LIBTMUX_SIGPIPE_PROBE"],
        path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path)
    else {
        throw ContractFixtureError.missingProcessProbe
    }
    return path
}

func probeRequest(
    _ arguments: [String],
    environment: [String: String] = [:],
    workingDirectory: String? = nil,
    outputPolicy: OutputPolicy = .complete
) throws -> ProcessRequest {
    try ProcessRequest(
        executable: .path(processProbePath()),
        arguments: arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        outputPolicy: outputPolicy
    )
}

func lengthPrefixed(_ values: [[UInt8]]) -> [UInt8] {
    values.flatMap { value in
        withUnsafeBytes(of: UInt64(value.count).bigEndian, Array.init) + value
    }
}

func processIdentifier(from bytes: [UInt8]) throws -> Int32 {
    guard
        let value = Int32(
            String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    else {
        throw ContractFixtureError.invalidProbeReply
    }
    return value
}

func processIsRunning(_ processIdentifier: Int32) -> Bool {
    #if os(Linux)
        if let status = try? String(
            contentsOfFile: "/proc/\(processIdentifier)/stat",
            encoding: .utf8
        ), let closeParenthesis = status.lastIndex(of: ")") {
            let stateIndex = status.index(closeParenthesis, offsetBy: 2)
            if stateIndex < status.endIndex, status[stateIndex] == "Z" { return false }
        }
    #endif
    if kill(processIdentifier, 0) == 0 {
        return true
    }
    return errno != ESRCH
}

func descriptorCount() throws -> Int {
    #if os(Linux)
        return try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
    #else
        return try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    #endif
}

struct DescriptorSnapshot: Sendable, CustomStringConvertible {
    let targets: [Int: String]

    var description: String {
        targets.keys.sorted().map { descriptor in
            "\(descriptor)=\(targets[descriptor] ?? "<missing>")"
        }.joined(separator: ", ")
    }
}

enum DescriptorTargetClass: Sendable, Equatable {
    case runtime
    case pipe
    case socket
    case processDescriptor
    case other
    case closedAfterSnapshot
}

struct TransportDescriptorCounts: Sendable, Equatable, CustomStringConvertible {
    let pipeCount: Int
    let socketCount: Int
    let processDescriptorCount: Int
    let otherCount: Int

    var nonRuntimeCount: Int {
        pipeCount + socketCount + processDescriptorCount + otherCount
    }

    /// Leak evidence is growth. This census covers the whole test process, so a
    /// concurrently running suite closing its own descriptors can drive a
    /// category below the baseline without this transport having leaked.
    func doesNotExceed(_ baseline: Self) -> Bool {
        pipeCount <= baseline.pipeCount
            && socketCount <= baseline.socketCount
            && processDescriptorCount <= baseline.processDescriptorCount
            && otherCount <= baseline.otherCount
    }

    var description: String {
        "nonRuntime=\(nonRuntimeCount), pipes=\(pipeCount), sockets=\(socketCount), "
            + "pidfds=\(processDescriptorCount), other=\(otherCount)"
    }
}

func descriptorTargetClass(_ target: String) -> DescriptorTargetClass {
    switch target {
    case "anon_inode:[eventfd]", "anon_inode:[eventpoll]", "anon_inode:[timerfd]":
        return .runtime
    case "anon_inode:[pidfd]":
        return .processDescriptor
    case "<closed-after-snapshot>":
        return .closedAfterSnapshot
    default:
        if target.hasPrefix("pipe:[") { return .pipe }
        if target.hasPrefix("socket:[") { return .socket }
        return .other
    }
}

func transportDescriptorCounts(
    from snapshot: DescriptorSnapshot
) -> TransportDescriptorCounts {
    var pipeCount = 0
    var socketCount = 0
    var processDescriptorCount = 0
    var otherCount = 0
    for target in snapshot.targets.values {
        switch descriptorTargetClass(target) {
        case .runtime, .closedAfterSnapshot:
            break
        case .pipe:
            pipeCount += 1
        case .socket:
            socketCount += 1
        case .processDescriptor:
            processDescriptorCount += 1
        case .other:
            otherCount += 1
        }
    }
    return TransportDescriptorCounts(
        pipeCount: pipeCount,
        socketCount: socketCount,
        processDescriptorCount: processDescriptorCount,
        otherCount: otherCount
    )
}

func transportDescriptorCounts() throws -> TransportDescriptorCounts {
    transportDescriptorCounts(from: try descriptorSnapshot())
}

func descriptorSnapshot() throws -> DescriptorSnapshot {
    #if os(Linux)
        let directory = "/proc/self/fd"
    #else
        let directory = "/dev/fd"
    #endif
    let names = try FileManager.default.contentsOfDirectory(atPath: directory)
    let pairs: [(Int, String)] = names.compactMap { name in
        guard let descriptor = Int(name) else { return nil }
        let path = "\(directory)/\(name)"
        let target: String
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            target = resolved
        } else if fcntl(Int32(descriptor), F_GETFD) >= 0 {
            target = "<live-unresolved>"
        } else {
            target = "<closed-after-snapshot>"
        }
        return (descriptor, target)
    }
    let targets = Dictionary(uniqueKeysWithValues: pairs)
    return DescriptorSnapshot(targets: targets)
}

@Suite("transport bakeoff", .serialized)
struct TransportBakeoffSuite {}

extension TransportBakeoffSuite {
    @Suite("one-shot transport contract")
    struct TransportContractTests {
        @Test("argv boundaries survive shell metacharacters", arguments: TransportKind.allCases)
        func argvBoundariesSurviveShellMetacharacters(_ kind: TransportKind) async throws {
            let values = ["space value", "'\"", ";$(false)", "line\nbreak", "*?[x]"]
            let reply = try await kind.transport().run(try probeRequest(["argv"] + values))

            #expect(reply.standardOutput == lengthPrefixed(values.map { Array($0.utf8) }))
            #expect(reply.standardError.isEmpty)
            #expect(reply.termination == .exited(0))
        }

        @Test("environment and working directory are exact", arguments: TransportKind.allCases)
        func environmentAndWorkingDirectoryAreExact(_ kind: TransportKind) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "libtmux-%20-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let reply = try await kind.transport().run(
                try probeRequest(
                    ["context", "LIBTMUX_ALPHA", "LIBTMUX_EMPTY", "PATH"],
                    environment: ["LIBTMUX_ALPHA": "a b\n$c", "LIBTMUX_EMPTY": "", "PATH": "/bin"],
                    workingDirectory: directory.path
                )
            )

            #expect(
                reply.standardOutput
                    == lengthPrefixed(
                        [directory.path, "a b\n$c", "", "/bin"].map { Array($0.utf8) }
                    )
            )
            #expect(ProcessInfo.processInfo.environment["LIBTMUX_ALPHA"] == nil)
        }

        @Test("empty output and exit statuses remain reply data", arguments: TransportKind.allCases)
        func emptyOutputAndExitStatusesRemainReplyData(_ kind: TransportKind) async throws {
            let success = try await kind.transport().run(try probeRequest(["exit", "0"]))
            let failure = try await kind.transport().run(try probeRequest(["exit", "23"]))
            let signal = try await kind.transport().run(try probeRequest(["signal", "15"]))

            #expect(
                success
                    == ProcessReply(standardOutput: [], standardError: [], termination: .exited(0)))
            #expect(failure.termination == .exited(23))
            #expect(signal.termination == .unhandledSignal(15))
        }

        @Test("both large streams are complete", arguments: TransportKind.allCases)
        func bothLargeStreamsAreComplete(_ kind: TransportKind) async throws {
            let reply = try await kind.transport().run(
                try probeRequest(["alternate", "257", "4096"]))

            #expect(reply.standardOutput == [UInt8](repeating: 0x41, count: 257 * 4096))
            #expect(reply.standardError == [UInt8](repeating: 0x42, count: 257 * 4096))
            #expect(reply.termination == .exited(0))
        }

        @Test(
            "complete output ramp is byte-lossless and deadline-bounded",
            arguments: TransportKind.allCases,
            outputRampByteCounts
        )
        func completeOutputRampIsByteLosslessAndDeadlineBounded(
            _ kind: TransportKind,
            _ byteCount: Int
        ) async throws {
            let chunkCount = 256
            let chunkSize = byteCount / chunkCount
            let reply = try await withContractDeadline {
                try await kind.transport().run(
                    try probeRequest(["alternate", String(chunkCount), String(chunkSize)])
                )
            }

            #expect(reply.standardOutput == [UInt8](repeating: 0x41, count: byteCount))
            #expect(reply.standardError == [UInt8](repeating: 0x42, count: byteCount))
            #expect(reply.termination == .exited(0))
        }

        @Test("invalid UTF-8 remains byte lossless", arguments: TransportKind.allCases)
        func invalidUTF8RemainsByteLossless(_ kind: TransportKind) async throws {
            let reply = try await kind.transport().run(
                try probeRequest(["invalid", "ff00c328", "fe80c0"])
            )

            #expect(reply.standardOutput == [0xff, 0x00, 0xc3, 0x28])
            #expect(reply.standardError == [0xfe, 0x80, 0xc0])
        }

        @Test("missing executables are invocation errors", arguments: TransportKind.allCases)
        func missingExecutablesAreInvocationErrors(_ kind: TransportKind) async throws {
            let request = try ProcessRequest(
                executable: .path("/libtmux/no-such-executable"),
                arguments: [],
                environment: [:],
                workingDirectory: nil,
                outputPolicy: .complete
            )

            do {
                _ = try await kind.transport().run(request)
                Issue.record("missing executable returned reply data")
            } catch is ProcessInvocationError {
            }
        }

        @Test("direct spawn survives closed host standard descriptors")
        func directSpawnSurvivesClosedHostStandardDescriptors() async throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString
            )
            var cleanupProcessGroup: Int32?
            let task = Task {
                try await FoundationProcessTransport().run(
                    ProcessRequest(
                        executable: .path(try sacrificialProbePath()),
                        arguments: ["closed-stdio", marker.path],
                        environment: ["LIBTMUX_PROCESS_PROBE": try processProbePath()],
                        workingDirectory: nil,
                        outputPolicy: .complete
                    )
                )
            }
            defer {
                task.cancel()
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: marker)
            }
            let tree = try await waitForProbeMarker(marker)
            cleanupProcessGroup = tree.processGroup
            let reply = try await withContractDeadline(
                operation: { try await task.value },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )

            #expect(reply.termination == .exited(0))
            #expect(reply.standardOutput.isEmpty)
            #expect(reply.standardError.isEmpty)
            #expect(tree.leader == tree.processGroup)
            try await waitForProcessRecordAbsence(tree.leader)
            #expect(processRecordIsAbsent(tree.leader))
            if processRecordIsAbsent(tree.leader) { cleanupProcessGroup = nil }
        }

        @Test("direct spawn closes staged pipes when later acquisition fails")
        func directSpawnClosesStagedPipesWhenLaterAcquisitionFails() throws {
            let before = try descriptorCount()
            for failureAttempt in [2, 3] {
                var attempts = 0
                do {
                    _ = try acquirePOSIXPipes(interactive: true) {
                        attempts += 1
                        if attempts == failureAttempt { throw InjectedPipeFailure.exhausted }
                        return try makeCLOEXECPipe()
                    }
                    Issue.record("injected pipe exhaustion unexpectedly succeeded")
                } catch InjectedPipeFailure.exhausted {
                }

                #expect(attempts == failureAttempt)
                #expect(try descriptorCount() == before)
            }

            var attempts = 0
            do {
                _ = try acquirePOSIXPipes(
                    interactive: false,
                    makePipe: {
                        attempts += 1
                        return try makeCLOEXECPipe()
                    },
                    openNullInput: { throw InjectedPipeFailure.exhausted }
                )
                Issue.record("injected null-input exhaustion unexpectedly succeeded")
            } catch InjectedPipeFailure.exhausted {
            }

            #expect(attempts == 2)
            #expect(try descriptorCount() == before)
        }

        @Test("direct spawn starts with inherited SIGTERM unblocked")
        func directSpawnStartsWithInheritedSIGTERMUnblocked() async throws {
            let process = try spawnWithBlockedSignal(
                SIGTERM,
                request: try probeRequest([
                    "signal-mask-membership", String(SIGTERM),
                ])
            )
            let owner = POSIXProcessOwner(process: process)
            let reply = try await collectSpawnedPOSIXReply(process, owner: owner)

            #expect(reply.standardOutput == Array("0\n".utf8))
            #expect(reply.standardError.isEmpty)
            #expect(reply.termination == .exited(0))
        }

        @Test("direct spawn resets an inherited ignored SIGTERM")
        func directSpawnResetsAnInheritedIgnoredSIGTERM() async throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                "libtmux-sigdef-\(UUID().uuidString)"
            )
            let helper = try spawnPOSIX(
                request: ProcessRequest(
                    executable: .path(try sacrificialProbePath()),
                    arguments: ["direct-spawn-default-signal", marker.path],
                    environment: ["LIBTMUX_PROCESS_PROBE": try processProbePath()],
                    workingDirectory: nil,
                    outputPolicy: .complete
                ),
                interactive: false
            )
            let owner = POSIXProcessOwner(process: helper)
            let completion = Task {
                try await collectSpawnedPOSIXReply(helper, owner: owner)
            }
            defer { try? FileManager.default.removeItem(at: marker) }

            var child: ProbeProcessTree?
            do {
                child = try await waitForProbeMarker(marker)
                guard let child, child.descendant == 0, child.leader == child.processGroup else {
                    throw ContractFixtureError.invalidProbeReply
                }
                let reply = try await withContractDeadline(
                    operation: { try await completion.value },
                    onTimeout: { completion.cancel() }
                )

                #expect(reply.standardOutput.isEmpty)
                #expect(reply.standardError.isEmpty)
                #expect(reply.termination == .exited(0))
                try await waitForProcessRecordAbsence(child.leader)
                try await waitForProcessRecordAbsence(helper.processIdentifier)
                #expect(processRecordIsAbsent(child.leader))
                #expect(processRecordIsAbsent(helper.processIdentifier))
            } catch {
                completion.cancel()
                _ = await completion.result
                if let child {
                    try? await waitForProcessRecordAbsence(child.leader)
                    #expect(processRecordIsAbsent(child.leader))
                }
                try? await waitForProcessRecordAbsence(helper.processIdentifier)
                #expect(processRecordIsAbsent(helper.processIdentifier))
                throw error
            }
        }

        @Test("shared input pipe normalizes descriptors and enables close-on-exec")
        func sharedInputPipeNormalizesDescriptorsAndEnablesCloseOnExec() throws {
            let descriptors = try makeCLOEXECPipe()
            defer { closePipe(descriptors) }

            #expect(descriptors.allSatisfy { $0 > STDERR_FILENO })
            for descriptor in descriptors {
                let flags = fcntl(descriptor, F_GETFD)
                #expect(flags >= 0)
                #expect(flags & FD_CLOEXEC != 0)
            }
        }

        @Test("per-stream limits throw a library error", arguments: TransportKind.allCases)
        func perStreamLimitsThrowALibraryError(_ kind: TransportKind) async throws {
            do {
                _ = try await kind.transport().run(
                    try probeRequest(
                        ["alternate", "8", "4096"],
                        outputPolicy: .limited(maxBytesPerStream: 4096)
                    )
                )
                Issue.record("oversized output returned a reply")
            } catch let error as ProcessOutputLimitError {
                #expect(error.limit == 4096)
                #expect(error.stream == .standardOutput || error.stream == .standardError)
            }
        }

        @Test(
            "per-stream limits accept exact bytes and reject one extra byte",
            arguments: TransportKind.allCases,
            [ProcessOutputStream.standardOutput, .standardError]
        )
        func perStreamLimitsAcceptExactBytesAndRejectOneExtraByte(
            _ kind: TransportKind,
            _ stream: ProcessOutputStream
        ) async throws {
            let name = stream == .standardOutput ? "stdout" : "stderr"
            let byte: UInt8 = stream == .standardOutput ? 0x45 : 0x46
            let limit = 8_192
            let exact = try await kind.transport().run(
                try probeRequest(
                    ["finite-stream", name, String(limit)],
                    outputPolicy: .limited(maxBytesPerStream: limit)
                )
            )
            #expect(exact.termination == .exited(0))
            #expect(
                (stream == .standardOutput ? exact.standardOutput : exact.standardError)
                    == [UInt8](repeating: byte, count: limit)
            )

            do {
                _ = try await kind.transport().run(
                    try probeRequest(
                        ["finite-stream", name, String(limit + 1)],
                        outputPolicy: .limited(maxBytesPerStream: limit)
                    )
                )
                Issue.record("limit plus one byte returned reply data")
            } catch let error as ProcessOutputLimitError {
                #expect(error == ProcessOutputLimitError(stream: stream, limit: limit))
            }
        }

        @Test(
            "stderr-first overflow is not rewritten as stdout",
            arguments: [TransportKind.swiftSubprocess, .directSpawn]
        )
        func stderrFirstOverflowIsNotRewrittenAsStdout(_ kind: TransportKind) async throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            var cleanupProcessGroup: Int32?
            let task = Task {
                try await kind.transport().run(
                    try probeRequest(
                        ["limit-stderr-first", marker.path, "1048576"],
                        outputPolicy: .limited(maxBytesPerStream: 8_192)
                    )
                )
            }
            defer {
                task.cancel()
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: marker)
            }
            let tree = try await waitForProbeMarker(marker)
            cleanupProcessGroup = tree.processGroup
            do {
                _ = try await withContractDeadline(
                    operation: { try await task.value },
                    onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
                )
                Issue.record("stderr-first overflow returned reply data")
            } catch let error as ProcessOutputLimitError {
                #expect(error == ProcessOutputLimitError(stream: .standardError, limit: 8_192))
            }
            try await waitForProcessRecordAbsence(tree.leader)
            try await waitForProcessRecordAbsence(tree.descendant)
            #expect(processRecordIsAbsent(tree.leader))
            #expect(processRecordIsAbsent(tree.descendant))
            if processRecordIsAbsent(tree.leader), processRecordIsAbsent(tree.descendant) {
                cleanupProcessGroup = nil
            }
        }

        @Test("simultaneous overflow arbitration has exactly one winner")
        func simultaneousOverflowArbitrationHasExactlyOneWinner() async {
            let arbiter = OutputLimitArbiter(limit: 1)
            let winners = await withTaskGroup(of: ProcessOutputStream?.self) { group in
                for stream in [ProcessOutputStream.standardOutput, .standardError] {
                    group.addTask { arbiter.exceeded(on: stream) ? stream : nil }
                }
                return await group.reduce(into: [ProcessOutputStream]()) { winners, winner in
                    if let winner { winners.append(winner) }
                }
            }

            #expect(winners.count == 1)
            #expect(arbiter.error == ProcessOutputLimitError(stream: winners[0], limit: 1))
        }

        @Test(
            "limit cleanup names the exact stream and kills descendants",
            arguments: [TransportKind.swiftSubprocess, .directSpawn],
            [ProcessOutputStream.standardOutput, .standardError]
        )
        func limitCleanupNamesTheExactStreamAndKillsDescendants(
            _ kind: TransportKind,
            _ stream: ProcessOutputStream
        ) async throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            var cleanupProcessGroup: Int32?
            let mode = stream == .standardOutput ? "limit-stdout" : "limit-stderr"
            let task = Task {
                try await kind.transport().run(
                    try probeRequest(
                        [mode, marker.path, "4096"],
                        outputPolicy: .limited(maxBytesPerStream: 8192)
                    )
                )
            }
            defer {
                task.cancel()
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: marker)
            }
            let tree = try await waitForProbeMarker(marker)
            cleanupProcessGroup = tree.processGroup
            do {
                _ = try await withContractDeadline(
                    operation: { try await task.value },
                    onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
                )
                Issue.record("limited producer returned reply data")
            } catch let error as ProcessOutputLimitError {
                #expect(error == ProcessOutputLimitError(stream: stream, limit: 8192))
            }
            try await waitForProcessRecordAbsence(tree.leader)
            try await waitForProcessRecordAbsence(tree.descendant)
            #expect(processRecordIsAbsent(tree.leader))
            #expect(processRecordIsAbsent(tree.descendant))
            if processRecordIsAbsent(tree.leader), processRecordIsAbsent(tree.descendant) {
                cleanupProcessGroup = nil
            }
        }

        @Test("swift-subprocess limit kills a SIGTERM-ignoring descendant")
        func swiftSubprocessLimitKillsASIGTERMIgnoringDescendant() async throws {
            #if os(Linux)
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                var cleanupDescendant: Int32?
                let task = Task {
                    try await SwiftSubprocessTransport().run(
                        try probeRequest(
                            ["limit-stubborn-descendant", marker.path, "4096"],
                            outputPolicy: .limited(maxBytesPerStream: 8192)
                        )
                    )
                }
                defer {
                    task.cancel()
                    if let cleanupDescendant,
                        processIsRunning(cleanupDescendant),
                        processHasExactArgument(cleanupDescendant, marker.path)
                    {
                        _ = kill(cleanupDescendant, SIGKILL)
                    }
                    try? FileManager.default.removeItem(at: marker)
                }

                let tree = try await waitForProbeMarker(marker)
                cleanupDescendant = tree.descendant
                do {
                    _ = try await withContractDeadline { try await task.value }
                    Issue.record("limited producer returned reply data")
                } catch let error as ProcessOutputLimitError {
                    #expect(
                        error
                            == ProcessOutputLimitError(
                                stream: .standardOutput,
                                limit: 8192
                            )
                    )
                }
                try await waitForProcessRecordAbsence(tree.leader)
                let descendantRemoved = try await processRecordBecomesAbsent(
                    tree.descendant,
                    within: .seconds(1)
                )
                #expect(descendantRemoved)
                if !descendantRemoved,
                    processIsRunning(tree.descendant),
                    processHasExactArgument(tree.descendant, marker.path)
                {
                    _ = kill(tree.descendant, SIGKILL)
                }
                try await waitForProcessRecordAbsence(tree.descendant)
                if processRecordIsAbsent(tree.descendant) { cleanupDescendant = nil }
            #endif
        }

        @Test("Foundation is disqualified from limit process-group cleanup")
        func foundationIsDisqualifiedFromLimitProcessGroupCleanup() {
            #expect(!FoundationProcessTransport.providesProcessGroupIsolation)
        }

        @Test("swift-subprocess repeated runs reap children and bound descriptors")
        func swiftSubprocessRepeatedRunsReapChildrenAndBoundDescriptors() async throws {
            try await assertRepeatedRunsAreBounded(.swiftSubprocess)
        }

        @Test("Foundation repeated runs reap children and bound descriptors")
        func foundationRepeatedRunsReapChildrenAndBoundDescriptors() async throws {
            try await assertRepeatedRunsAreBounded(.foundation)
        }

        @Test("direct spawn repeated runs reap children and bound descriptors")
        func directSpawnRepeatedRunsReapChildrenAndBoundDescriptors() async throws {
            try await assertRepeatedRunsAreBounded(.directSpawn)
        }

        private func assertRepeatedRunsAreBounded(_ kind: TransportKind) async throws {
            for _ in 0..<32 {
                _ = try await kind.transport().run(try probeRequest(["pid"]))
            }
            let before = try descriptorSnapshot()
            let beforeCounts = transportDescriptorCounts(from: before)
            var processIdentifiers: [Int32] = []
            for _ in 0..<32 {
                let reply = try await kind.transport().run(try probeRequest(["pid"]))
                processIdentifiers.append(try processIdentifier(from: reply.standardOutput))
            }
            let immediate = try descriptorSnapshot()
            let settled = try await leakRelevantDescriptorsReturn(to: beforeCounts)
            let settledCounts = transportDescriptorCounts(from: settled)
            let evidence =
                "baseline [\(beforeCounts); \(before)]; immediate [\(immediate)]; "
                + "settled [\(settledCounts); \(settled)]"
            #expect(
                settledCounts.doesNotExceed(beforeCounts),
                Comment(rawValue: evidence)
            )
            for processIdentifier in processIdentifiers {
                try await waitForProcessRecordAbsence(processIdentifier)
            }
            #expect(processIdentifiers.allSatisfy(processRecordIsAbsent))
        }
    }
}

func leakRelevantDescriptorsReturn(
    to expected: TransportDescriptorCounts
) async throws -> DescriptorSnapshot {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        let snapshot = try descriptorSnapshot()
        if transportDescriptorCounts(from: snapshot).doesNotExceed(expected) {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try descriptorSnapshot()
}
