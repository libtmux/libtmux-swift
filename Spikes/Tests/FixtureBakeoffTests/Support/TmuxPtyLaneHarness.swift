import Foundation
import Testing

@testable import FixtureBakeoff
@testable import SpikeSupport
@testable import TransportBakeoff

struct LiveTmuxSession: Sendable, Equatable {
    let identifier: String
    let name: String
    let pane: String
}

struct TmuxClientRecord: Sendable, Equatable {
    let name: String
    let processIdentifier: Int32
    let tty: String
    let controlMode: Int
    let width: Int
    let height: Int
    let session: String
    let sessionIdentifier: String
}

struct TmuxLane: Sendable {
    let binary: String
    let root: URL
    let path: String
    let developerDirectory: String?
    let sdkRoot: String?

    /// Runtime state the lane sandbox exports as `XDG_RUNTIME_DIR`. Fixtures
    /// live here rather than in the lane root so their scratch sibling stays
    /// outside every run root.
    var runtimeRoot: URL {
        root.appendingPathComponent("run", isDirectory: true)
    }

    /// Scratch the lane sandbox exports as `TMPDIR`.
    var temporaryDirectory: URL {
        root.appendingPathComponent("tmp", isDirectory: true)
    }

    func fixtureConfiguration(
        runRoot: URL? = nil,
        checkpoints: FixtureLifecycleCheckpoints = FixtureLifecycleCheckpoints()
    ) -> FixtureConfiguration {
        FixtureConfiguration(
            runRoot: runRoot ?? runtimeRoot,
            tmuxExecutable: .path(binary),
            childEnvironment: FixtureChildEnvironment(
                path: path,
                temporaryDirectory: temporaryDirectory.path,
                developerDirectory: developerDirectory,
                sdkRoot: sdkRoot
            ),
            // A hang detector, not a latency budget: a lane holding dozens
            // of concurrent fixtures queues far past the time one lifecycle
            // needs, and the suite time limit bounds a genuine hang.
            startupDeadline: .seconds(30),
            cleanupDeadline: .seconds(30),
            checkpointInterval: .milliseconds(10),
            checkpoints: checkpoints
        )
    }

    var childEnvironment: [String: String] {
        var environment = [
            "LC_ALL": "C",
            "PATH": path,
            "TERM": "xterm-256color",
            "TMPDIR": temporaryDirectory.path,
        ]
        if let developerDirectory {
            environment["DEVELOPER_DIR"] = developerDirectory
        }
        if let sdkRoot {
            environment["SDKROOT"] = sdkRoot
        }
        return environment
    }
}

enum TmuxLaneAuthenticationError: Error, Sendable, Equatable {
    case binaryPathMismatch(expected: String, actual: String)
    case invalidEnvironment(String)
    case laneCountMismatch(tag: String, count: Int)
    case sandboxPathMismatch(key: String, expected: String, actual: String)
}

private enum TmuxRequestObservation: Sendable {
    case failed
    case pending
    case reply(ProcessReply)
}

private actor TmuxRequestState {
    private var observation = TmuxRequestObservation.pending

    func fail() {
        observation = .failed
    }

    func finish(_ reply: ProcessReply) {
        observation = .reply(reply)
    }

    func current() -> TmuxRequestObservation {
        observation
    }
}

struct OwnedTmuxRequest: Sendable {
    fileprivate let state: TmuxRequestState
    fileprivate let owner: Task<Void, Never>
}

/// Authenticating a lane rehashes every pinned tmux binary, so the result is
/// resolved once for the test process instead of once per test case.
private let sharedAuthenticatedTmuxLane: TmuxLane? = try? authenticatedTmuxLane(
    environment: ProcessInfo.processInfo.environment,
    laneDeclarationAt: fixtureLaneDeclarationURL
)

func authenticatedTmuxLane() throws -> TmuxLane {
    if let sharedAuthenticatedTmuxLane { return sharedAuthenticatedTmuxLane }
    return try authenticatedTmuxLane(
        environment: ProcessInfo.processInfo.environment,
        laneDeclarationAt: fixtureLaneDeclarationURL
    )
}

func authenticatedTmuxLane(
    environment: [String: String],
    laneDeclarationAt laneDeclaration: URL
) throws -> TmuxLane {
    let binary = try authenticatedLaneExecutable(
        "LIBTMUX_TMUX_BIN",
        environment: environment
    )
    let tag = try authenticatedLaneValue("LIBTMUX_TMUX_TAG", environment: environment)
    let root = try authenticatedLaneDirectory(
        "LIBTMUX_MATRIX_ROOT",
        environment: environment
    )
    let manifest = try authenticatedLaneFile(
        "LIBTMUX_MATRIX_MANIFEST",
        environment: environment
    )
    let binaryRoot = try authenticatedLaneDirectory(
        "LIBTMUX_MATRIX_BINARY_ROOT",
        environment: environment
    )
    for (key, child) in [
        ("TMPDIR", "tmp"),
        ("XDG_RUNTIME_DIR", "run"),
        ("XDG_CONFIG_HOME", "config"),
    ] {
        let actual = try authenticatedLaneDirectory(key, environment: environment)
        let expected = root.appendingPathComponent(child, isDirectory: true).path
        guard actual.path == expected else {
            throw TmuxLaneAuthenticationError.sandboxPathMismatch(
                key: key,
                expected: expected,
                actual: actual.path
            )
        }
    }

    let matrix = try TmuxMatrix.load(
        laneDeclarationAt: laneDeclaration,
        evidenceAt: manifest,
        binariesAt: binaryRoot
    )
    let matchingLanes = matrix.lanes.filter { $0.rawTag == tag }
    guard matchingLanes.count == 1, let authenticated = matchingLanes.first else {
        throw TmuxLaneAuthenticationError.laneCountMismatch(
            tag: tag,
            count: matchingLanes.count
        )
    }
    guard authenticated.executablePath == binary else {
        throw TmuxLaneAuthenticationError.binaryPathMismatch(
            expected: authenticated.executablePath,
            actual: binary
        )
    }

    _ = try authenticatedLaneExecutable(
        "LIBTMUX_PTY_CLIENT_PROBE",
        environment: environment
    )
    return TmuxLane(
        binary: binary,
        root: root,
        path: environment["PATH"] ?? "/usr/bin:/bin",
        developerDirectory: environment["DEVELOPER_DIR"],
        sdkRoot: environment["SDKROOT"]
    )
}

private func authenticatedLaneValue(
    _ key: String,
    environment: [String: String]
) throws -> String {
    guard let value = environment[key], !value.isEmpty else {
        throw PtyClientContractError.missingEnvironment(key)
    }
    return value
}

private func authenticatedLaneURL(
    _ key: String,
    environment: [String: String],
    isDirectory: Bool
) throws -> URL {
    let path = try authenticatedLaneValue(key, environment: environment)
    let candidate = URL(fileURLWithPath: path, isDirectory: isDirectory)
    let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
    guard path.hasPrefix("/"), candidate.standardizedFileURL.path == path,
        canonical.path == path
    else {
        throw TmuxLaneAuthenticationError.invalidEnvironment(key)
    }
    return canonical
}

private func authenticatedLaneDirectory(
    _ key: String,
    environment: [String: String]
) throws -> URL {
    let directory = try authenticatedLaneURL(
        key,
        environment: environment,
        isDirectory: true
    )
    var isDirectory = ObjCBool(false)
    guard
        FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
    else {
        throw TmuxLaneAuthenticationError.invalidEnvironment(key)
    }
    return directory
}

private func authenticatedLaneFile(
    _ key: String,
    environment: [String: String]
) throws -> URL {
    let file = try authenticatedLaneURL(
        key,
        environment: environment,
        isDirectory: false
    )
    var isDirectory = ObjCBool(false)
    guard
        FileManager.default.fileExists(
            atPath: file.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue
    else {
        throw TmuxLaneAuthenticationError.invalidEnvironment(key)
    }
    return file
}

private func authenticatedLaneExecutable(
    _ key: String,
    environment: [String: String]
) throws -> String {
    let file = try authenticatedLaneFile(key, environment: environment)
    guard FileManager.default.isExecutableFile(atPath: file.path) else {
        throw TmuxLaneAuthenticationError.invalidEnvironment(key)
    }
    return file.path
}

private let fixtureLaneDeclarationURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/tmux-matrix.json")

func makeSelectedTmuxTransport() -> any ProcessTransport {
    SwiftSubprocessTransport()
}

func withRealTmuxFixture<Result: Sendable>(
    lane: TmuxLane,
    body: @escaping @Sendable (TmuxFixture) async throws -> Result
) async throws -> Result {
    try await withTmuxServer(
        configuration: lane.fixtureConfiguration(),
        transport: makeSelectedTmuxTransport(),
        secondaryCleanupFailureSink: { cleanupError in
            Issue.record("fixture cleanup also failed: \(cleanupError)")
        },
        body: body
    )
}

func launchAttachedTmuxClient(
    lane: TmuxLane,
    fixture: TmuxFixture,
    session: LiveTmuxSession
) async throws -> RunningPtyClient {
    try await launchPtyClient(
        executable: lane.binary,
        arguments: [
            "-N", "-S", try socketPath(fixture),
            "attach-session", "-t", session.identifier,
        ],
        environment: lane.childEnvironment
    )
}

func withAttachedTmuxClient<Result: Sendable>(
    lane: TmuxLane,
    fixture: TmuxFixture,
    body: (RunningPtyClient, LiveTmuxSession) async throws -> Result
) async throws -> Result {
    let session = try await soleLiveTmuxSession(lane: lane, fixture: fixture)
    let client = try await launchAttachedTmuxClient(
        lane: lane,
        fixture: fixture,
        session: session
    )
    do {
        return try await body(client, session)
    } catch {
        await stopAndReapPtyClient(client)
        throw error
    }
}

func socketPath(_ fixture: TmuxFixture) throws -> String {
    guard case let .socketPath(path) = fixture.endpoint else {
        throw PtyClientContractError.unexpectedEndpoint
    }
    return path
}

func launchTmuxRequest(
    lane: TmuxLane,
    fixture: TmuxFixture,
    arguments: [String],
    transport: any ProcessTransport = makeSelectedTmuxTransport()
) -> OwnedTmuxRequest {
    let state = TmuxRequestState()
    let owner = Task {
        do {
            let reply = try await transport.run(
                ProcessRequest(
                    executable: .path(lane.binary),
                    arguments: arguments,
                    environment: lane.childEnvironment,
                    workingDirectory: nil,
                    outputPolicy: .complete
                )
            )
            await state.finish(reply)
        } catch {
            await state.fail()
        }
    }
    return OwnedTmuxRequest(state: state, owner: owner)
}

func awaitTmuxRequest(
    _ request: OwnedTmuxRequest,
    within duration: Duration = .seconds(5)
) async throws -> ProcessReply {
    let deadline = ContinuousClock.now.advanced(by: duration)
    do {
        while ContinuousClock.now < deadline {
            switch await request.state.current() {
            case .failed:
                throw PtyClientContractError.tmuxTransportFailed
            case .pending:
                try await Task.sleep(for: .milliseconds(10))
            case let .reply(reply):
                await request.owner.value
                return reply
            }
        }
    } catch {
        await cancelAndReapTmuxRequest(request)
        throw error
    }
    await cancelAndReapTmuxRequest(request)
    throw PtyClientContractError.deadlineExceeded
}

func cancelAndReapTmuxRequest(_ request: OwnedTmuxRequest) async {
    request.owner.cancel()
    await request.owner.value
}

func runTmux(
    lane: TmuxLane,
    fixture: TmuxFixture,
    arguments: [String],
    transport: any ProcessTransport = makeSelectedTmuxTransport()
) async throws -> ProcessReply {
    try await awaitTmuxRequest(
        launchTmuxRequest(
            lane: lane,
            fixture: fixture,
            arguments: arguments,
            transport: transport
        )
    )
}

func requireSuccessfulTmuxReply(_ reply: ProcessReply) throws {
    guard reply.termination == .exited(0), reply.standardError.isEmpty else {
        throw PtyClientContractError.unexpectedTmuxReply(reply)
    }
}

private func singleTmuxReplyLine(_ reply: ProcessReply) throws -> String {
    try requireSuccessfulTmuxReply(reply)
    let lines = String(decoding: reply.standardOutput, as: UTF8.self)
        .split(whereSeparator: \Character.isNewline)
    guard lines.count == 1 else {
        throw PtyClientContractError.unexpectedTmuxReply(reply)
    }
    return String(lines[0])
}

func soleLiveTmuxSession(
    lane: TmuxLane,
    fixture: TmuxFixture
) async throws -> LiveTmuxSession {
    let identifiersReply = try await runTmux(
        lane: lane,
        fixture: fixture,
        arguments: [
            "-N", "-S", try socketPath(fixture),
            "list-sessions", "-F", "#{session_id}",
        ]
    )
    let sessionIdentifier = try singleTmuxReplyLine(identifiersReply)

    let nameReply = try await runTmux(
        lane: lane,
        fixture: fixture,
        arguments: [
            "-N", "-S", try socketPath(fixture),
            "display-message", "-p", "-t", sessionIdentifier,
            "#{session_name}",
        ]
    )
    let sessionName = try singleTmuxReplyLine(nameReply)

    let panesReply = try await runTmux(
        lane: lane,
        fixture: fixture,
        arguments: [
            "-N", "-S", try socketPath(fixture),
            "list-panes", "-t", sessionIdentifier,
            "-F", "#{pane_id}",
        ]
    )
    let paneIdentifier = try singleTmuxReplyLine(panesReply)
    return LiveTmuxSession(
        identifier: sessionIdentifier,
        name: sessionName,
        pane: paneIdentifier
    )
}

func waitForTmuxClient(
    lane: TmuxLane,
    fixture: TmuxFixture,
    processIdentifier: Int32
) async throws -> TmuxClientRecord {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
        let records = try await tmuxClients(lane: lane, fixture: fixture)
        if let record = records.first(where: { $0.processIdentifier == processIdentifier }) {
            return record
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PtyClientContractError.deadlineExceeded
}

func waitForTmuxClientAbsence(
    lane: TmuxLane,
    fixture: TmuxFixture,
    name: String
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
        let records = try await tmuxClients(lane: lane, fixture: fixture)
        if !records.contains(where: { $0.name == name }) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PtyClientContractError.deadlineExceeded
}

func tmuxClients(
    lane: TmuxLane,
    fixture: TmuxFixture,
    transport: any ProcessTransport = makeSelectedTmuxTransport()
) async throws -> [TmuxClientRecord] {
    let reply = try await runTmux(
        lane: lane,
        fixture: fixture,
        arguments: [
            "-N", "-u", "-S", try socketPath(fixture),
            "list-clients", "-F",
            "#{client_name}\t#{client_pid}\t#{client_tty}\t#{client_control_mode}\t#{client_width}\t#{client_height}\t#{client_session}\t#{session_id}",
        ],
        transport: transport
    )
    try requireSuccessfulTmuxReply(reply)
    return try String(decoding: reply.standardOutput, as: UTF8.self)
        .split(whereSeparator: \Character.isNewline)
        .map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 8,
                let processIdentifier = Int32(fields[1]),
                let controlMode = Int(fields[3]),
                let width = Int(fields[4]),
                let height = Int(fields[5])
            else {
                throw PtyClientContractError.invalidClientRecord
            }
            return TmuxClientRecord(
                name: String(fields[0]),
                processIdentifier: processIdentifier,
                tty: String(fields[2]),
                controlMode: controlMode,
                width: width,
                height: height,
                session: String(fields[6]),
                sessionIdentifier: String(fields[7])
            )
        }
}

func requireAttachedClientIdentity(
    _ record: TmuxClientRecord,
    client: RunningPtyClient,
    session: LiveTmuxSession
) throws {
    guard record.processIdentifier == client.readiness.childPID,
        !record.name.isEmpty,
        !record.tty.isEmpty,
        record.controlMode == 0,
        record.session == session.name,
        record.sessionIdentifier == session.identifier,
        record.tty == client.readiness.ptyPath
    else {
        throw PtyClientContractError.invalidClientRecord
    }
}

func waitForServerOption(
    lane: TmuxLane,
    fixture: TmuxFixture,
    option: String,
    value: String
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
        let reply = try await runTmux(
            lane: lane,
            fixture: fixture,
            arguments: [
                "-N", "-S", try socketPath(fixture),
                "show-options", "-sv", option,
            ]
        )
        if reply.termination == .exited(0), reply.standardError.isEmpty,
            String(decoding: reply.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == value
        {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PtyClientContractError.deadlineExceeded
}

func waitForTerminalText(
    _ text: String,
    client: RunningPtyClient
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
        if await client.transcript.contains(text) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PtyClientContractError.deadlineExceeded
}

func detach(
    _ client: RunningPtyClient,
    record: TmuxClientRecord,
    lane: TmuxLane,
    fixture: TmuxFixture
) async throws {
    let reply = try await runTmux(
        lane: lane,
        fixture: fixture,
        arguments: [
            "-N", "-S", try socketPath(fixture),
            "detach-client", "-t", record.name,
        ]
    )
    try requireSuccessfulTmuxReply(reply)
    let termination = try await awaitPtyTermination(client)
    guard termination == .exited(0) else {
        throw PtyClientContractError.sessionFailed
    }
    try await requireProcessRecordsAbsent([
        client.readiness.probePID,
        client.readiness.childPID,
    ])
}
