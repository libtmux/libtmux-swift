import Foundation
import Testing

@testable import PtyClientProbe
@testable import SpikeSupport

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

let ptyProtocolVersion = 1
let ptyRows = 37
let ptyColumns = 101

struct PtyProcessTree: Sendable, Equatable {
    let leader: Int32
    let descendant: Int32
    let processGroup: Int32
}

struct RunningPtyClient: Sendable {
    let owner: PtyProbeProcessOwner
    let readiness: PtyClientReadiness

    var transcript: TerminalTranscript {
        owner.transcript
    }

    func writeStandardInput(_ bytes: [UInt8]) throws {
        try owner.writeStandardInput(bytes)
    }

    func finishStandardInput() throws {
        try owner.finishStandardInput()
    }
}

actor PtyClientTracker {
    private var client: RunningPtyClient?

    func store(_ client: RunningPtyClient) {
        self.client = client
    }

    func take() -> RunningPtyClient? {
        defer { client = nil }
        return client
    }
}

func ptyProbeArguments(
    executable: String,
    arguments: [String]
) -> [String] {
    [
        "--rows", String(ptyRows),
        "--columns", String(ptyColumns),
        "--", executable,
    ] + arguments
}

func processProbePath() throws -> String {
    try requiredExecutable("LIBTMUX_PROCESS_PROBE")
}

func ptyClientProbePath() throws -> String {
    try requiredExecutable("LIBTMUX_PTY_CLIENT_PROBE")
}

func requiredExecutable(_ key: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[key],
        value.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: value)
    else {
        throw PtyClientContractError.missingEnvironment(key)
    }
    return value
}

func decodeLengthPrefixedArguments(_ bytes: [UInt8]) throws -> [String] {
    var index = bytes.startIndex
    var arguments: [String] = []
    while index < bytes.endIndex {
        guard bytes.distance(from: index, to: bytes.endIndex) >= 8 else {
            throw PtyClientContractError.invalidLengthPrefixedOutput
        }
        let lengthEnd = bytes.index(index, offsetBy: 8)
        let length = bytes[index..<lengthEnd].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard length <= UInt64(Int.max) else {
            throw PtyClientContractError.invalidLengthPrefixedOutput
        }
        let valueEnd = bytes.index(lengthEnd, offsetBy: Int(length), limitedBy: bytes.endIndex)
        guard let valueEnd,
            let value = String(bytes: bytes[lengthEnd..<valueEnd], encoding: .utf8)
        else {
            throw PtyClientContractError.invalidLengthPrefixedOutput
        }
        arguments.append(value)
        index = valueEnd
    }
    return arguments
}

func withRunningPtyClient<Result: Sendable>(
    executable: String,
    arguments: [String],
    environment: [String: String],
    body: (RunningPtyClient) async throws -> Result
) async throws -> Result {
    let client = try await launchPtyClient(
        executable: executable,
        arguments: arguments,
        environment: environment
    )
    do {
        return try await body(client)
    } catch {
        await stopAndReapPtyClient(client)
        throw error
    }
}

func launchPtyClient(
    executable: String,
    arguments: [String],
    environment: [String: String]
) async throws -> RunningPtyClient {
    let owner = try PtyProbeProcessOwner.launch(
        executable: try ptyClientProbePath(),
        arguments: ptyProbeArguments(executable: executable, arguments: arguments),
        environment: environment
    )
    do {
        let readiness = try await owner.waitForReadiness()
        try requireReadiness(
            readiness,
            ownerProcessIdentifier: owner.processIdentifier,
            rows: ptyRows,
            columns: ptyColumns
        )
        return RunningPtyClient(owner: owner, readiness: readiness)
    } catch {
        _ = try? await owner.stopAndReap(readiness: nil)
        throw error
    }
}

func requireReadiness(
    _ readiness: PtyClientReadiness,
    ownerProcessIdentifier: pid_t,
    rows: Int,
    columns: Int
) throws {
    guard readiness.protocolVersion == ptyProtocolVersion,
        readiness.probePID == ownerProcessIdentifier,
        readiness.childPID > 0,
        readiness.childProcessGroupID == readiness.childPID,
        readiness.childParentPID == readiness.probePID,
        readiness.childWasStoppedBeforeReadiness,
        readiness.ptyPath.hasPrefix("/dev/"),
        readiness.rows == rows,
        readiness.columns == columns
    else {
        throw PtyClientContractError.invalidReadiness
    }
}

func awaitPtyTermination(
    _ client: RunningPtyClient,
    within duration: Duration = .seconds(30)
) async throws -> ProcessTermination {
    do {
        if let termination = try await client.owner.waitIfComplete(within: duration) {
            return termination
        }
    } catch {
        _ = try? await client.owner.stopAndReap(readiness: client.readiness)
        throw error
    }
    _ = try await client.owner.stopAndReap(readiness: client.readiness)
    throw PtyClientContractError.deadlineExceeded
}

func stopAndReapPtyClient(_ client: RunningPtyClient) async {
    do {
        _ = try await client.owner.stopAndReap(readiness: client.readiness)
    } catch {
        Issue.record("PTY client cleanup failed: \(error)")
    }
}

func sendSignalToOwnedProbe(
    _ signal: Int32,
    client: RunningPtyClient
) throws {
    try client.owner.sendSignal(signal)
}

func waitForProcessMarker(_ marker: URL) async throws -> PtyProcessTree {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
        if let tree = processTree(from: marker) { return tree }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PtyClientContractError.invalidProcessMarker
}

private func processTree(from marker: URL) -> PtyProcessTree? {
    guard let data = try? Data(contentsOf: marker), !data.isEmpty else { return nil }
    let fields = String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \Character.isWhitespace)
    guard fields.count == 3,
        let leader = Int32(fields[0]),
        let descendant = Int32(fields[1]),
        let processGroup = Int32(fields[2])
    else { return nil }
    return PtyProcessTree(
        leader: leader,
        descendant: descendant,
        processGroup: processGroup
    )
}

func requireOwnedProcessTree(
    _ tree: PtyProcessTree,
    client: RunningPtyClient
) throws {
    guard client.readiness.probePID == client.owner.processIdentifier,
        client.readiness.childParentPID == client.readiness.probePID,
        client.readiness.childPID == tree.leader,
        client.readiness.childProcessGroupID == tree.processGroup,
        tree.leader == tree.processGroup,
        tree.descendant > 0,
        getpgid(tree.leader) == tree.processGroup,
        getpgid(tree.descendant) == tree.processGroup
    else {
        throw PtyClientContractError.invalidProcessRelationship
    }
}

func requireProcessRecordsAbsent(
    _ processIdentifiers: [Int32],
    within duration: Duration = .seconds(30)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: duration)
    while ContinuousClock.now < deadline {
        if processIdentifiers.allSatisfy(processRecordIsAbsent) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    for processIdentifier in processIdentifiers where !processRecordIsAbsent(processIdentifier) {
        throw PtyClientContractError.ownedProcessRemains(processIdentifier)
    }
}

#if os(Linux)
    func actualParentProcessIdentifier(_ processIdentifier: Int32) throws -> Int32 {
        let status = try String(
            contentsOfFile: "/proc/\(processIdentifier)/status",
            encoding: .utf8
        )
        guard
            let parentLine = status.split(separator: "\n").first(where: {
                $0.hasPrefix("PPid:")
            }),
            let parent = Int32(parentLine.dropFirst(5).trimmingCharacters(in: .whitespaces))
        else {
            throw PtyClientContractError.invalidProcessRelationship
        }
        return parent
    }

    func requireStoppedProcessRecord(
        _ processIdentifier: Int32,
        within duration: Duration = .seconds(30)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            if let status = try? String(
                contentsOfFile: "/proc/\(processIdentifier)/status",
                encoding: .utf8
            ),
                let state = status.split(separator: "\n").first(where: {
                    $0.hasPrefix("State:")
                }),
                state.contains("T") || state.contains("t")
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PtyClientContractError.invalidProcessRelationship
    }
#endif

private func processRecordIsAbsent(_ processIdentifier: Int32) -> Bool {
    #if os(Linux)
        return !FileManager.default.fileExists(atPath: "/proc/\(processIdentifier)")
    #else
        return kill(processIdentifier, 0) != 0 && errno == ESRCH
    #endif
}
