import Foundation
import Testing

@testable import FixtureBakeoff
@testable import SpikeSupport

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private let taskLocalCaseCount = 32
let inMemoryFixtureTransport = InMemoryFixtureTransport()
private let taskLocalOverlap = TaskLocalOverlap(expectedCount: taskLocalCaseCount)
let inMemoryFixtureConfiguration = FixtureConfiguration(
    runRoot: FileManager.default.temporaryDirectory,
    tmuxExecutable: .path("/fixture-bakeoff/fake-tmux"),
    childEnvironment: FixtureChildEnvironment(
        path: "/fixture-bakeoff/bin:/usr/bin",
        temporaryDirectory: "/fixture-bakeoff/tmp",
        developerDirectory: nil,
        sdkRoot: nil
    ),
    startupDeadline: .seconds(30),
    cleanupDeadline: .seconds(30),
    checkpointInterval: .milliseconds(1)
)

private enum TaskLocalContractError: Error, Sendable, Equatable {
    case duplicateArgument(Int)
    case missingConfiguration
    case missingSocket
    case missingToken
    case unexpectedRequest([String])
}

private struct TaskLocalOverlapSnapshot: Sendable {
    let argumentCount: Int
    let endpointCount: Int
    let tokenCount: Int
}

private actor TaskLocalOverlap {
    private let expectedCount: Int
    private let allEntered = AsyncGate()
    private var fixtures: [Int: TmuxFixture] = [:]

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func enter(
        argument: Int,
        fixture: TmuxFixture
    ) async throws -> TaskLocalOverlapSnapshot {
        guard fixtures[argument] == nil else {
            throw TaskLocalContractError.duplicateArgument(argument)
        }
        fixtures[argument] = fixture
        if fixtures.count == expectedCount {
            await allEntered.open()
        }
        try await allEntered.wait(timeout: .seconds(30))
        return TaskLocalOverlapSnapshot(
            argumentCount: fixtures.count,
            endpointCount: Set(fixtures.values.map(\.endpoint)).count,
            tokenCount: Set(fixtures.values.map(\.incarnation.token)).count
        )
    }
}

actor InMemoryFixtureTransport: ProcessTransport {
    private let cleanupReply: ProcessReply?
    private var tokensBySocket: [String: UUID] = [:]

    init(cleanupReply: ProcessReply? = nil) {
        self.cleanupReply = cleanupReply
    }

    func run(_ request: ProcessRequest) async throws -> ProcessReply {
        let socket = try taskLocalArgument(after: "-S", in: request.arguments)
        if request.arguments.contains("start-server") {
            let configuration = try taskLocalArgument(
                after: "-f",
                in: request.arguments
            )
            let token = try taskLocalToken(inConfiguration: configuration)
            try taskLocalCreateUnixSocketArtifact(at: socket)
            tokensBySocket[socket] = token
            return taskLocalReply(output: "\(token.uuidString)\n")
        }
        if request.arguments.contains("show-options") {
            guard let token = tokensBySocket[socket] else {
                throw TaskLocalContractError.missingToken
            }
            return taskLocalReply(output: "\(token.uuidString)\n")
        }
        if request.arguments.contains("has-session") {
            return taskLocalReply()
        }
        if request.arguments.contains("if-shell") {
            if let cleanupReply { return cleanupReply }
            guard request.arguments.indices.contains(6),
                request.arguments[6] == "kill-server"
            else {
                throw TaskLocalContractError.unexpectedRequest(request.arguments)
            }
            return taskLocalReply()
        }
        if request.arguments.contains("#{socket_path}") {
            tokensBySocket.removeValue(forKey: socket)
            return taskLocalReply(exitCode: 1)
        }
        throw TaskLocalContractError.unexpectedRequest(request.arguments)
    }

    var activeFixtureCount: Int {
        tokensBySocket.count
    }
}

private func taskLocalArgument(
    after flag: String,
    in arguments: [String]
) throws -> String {
    guard let index = arguments.firstIndex(of: flag),
        arguments.indices.contains(index + 1)
    else {
        if flag == "-S" {
            throw TaskLocalContractError.missingSocket
        }
        throw TaskLocalContractError.missingConfiguration
    }
    return arguments[index + 1]
}

private func taskLocalToken(inConfiguration path: String) throws -> UUID {
    let configuration = try String(
        contentsOf: URL(fileURLWithPath: path),
        encoding: .utf8
    )
    let tokens = Set(
        configuration.split { character in
            !(character.isHexDigit || character == "-")
        }.compactMap { UUID(uuidString: String($0)) }
    )
    guard tokens.count == 1, let token = tokens.first else {
        throw TaskLocalContractError.missingToken
    }
    return token
}

private func taskLocalReply(
    output: String = "",
    exitCode: Int32 = 0
) -> ProcessReply {
    ProcessReply(
        standardOutput: Array(output.utf8),
        standardError: [],
        termination: .exited(exitCode)
    )
}

private func taskLocalCreateUnixSocketArtifact(at path: String) throws {
    #if canImport(Darwin)
        let socketType = SOCK_STREAM
    #else
        let socketType = Int32(SOCK_STREAM.rawValue)
    #endif
    let descriptor = socket(AF_UNIX, socketType, 0)
    guard descriptor >= 0 else {
        throw TaskLocalContractError.unexpectedRequest(["socket", String(errno)])
    }
    defer { _ = close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let pathBytes = Array(path.utf8) + [UInt8(0)]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw TaskLocalContractError.unexpectedRequest(["socket-path", path])
    }
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.copyBytes(from: pathBytes)
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard result == 0 else {
        throw TaskLocalContractError.unexpectedRequest(["bind", String(errno)])
    }
}

private enum TaskLocalBodyError: Error, Sendable, Equatable {
    case expected
}

private actor TaskLocalCleanupFailures {
    private var failures: [FixtureCleanupError] = []

    func record(_ failure: FixtureCleanupError) {
        failures.append(failure)
    }

    var snapshot: [FixtureCleanupError] {
        failures
    }
}

private enum TaskLocalScopeError: Error {
    case unexpectedArtifact(String)
}

private struct TaskLocalTestScope {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lt-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        guard chmod(root.path, 0o700) == 0 else {
            throw TaskLocalScopeError.unexpectedArtifact("chmod-root")
        }
    }

    var configuration: FixtureConfiguration {
        FixtureConfiguration(
            runRoot: root,
            tmuxExecutable: .path("/fixture-bakeoff/fake-tmux"),
            childEnvironment: FixtureChildEnvironment(
                path: "/fixture-bakeoff/bin:/usr/bin",
                temporaryDirectory: "/fixture-bakeoff/tmp",
                developerDirectory: nil,
                sdkRoot: nil
            ),
            startupDeadline: .seconds(30),
            cleanupDeadline: .seconds(30),
            checkpointInterval: .milliseconds(1)
        )
    }

    func removeKnownArtifacts() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]
        )
        var fixtureDirectories: [URL] = []
        var recoverySidecars: [URL] = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            let name = entry.lastPathComponent
            if name.hasPrefix("f-"), values.isDirectory == true,
                values.isSymbolicLink != true
            {
                fixtureDirectories.append(entry)
                continue
            }
            // Preserved cleanup leaves the locked recovery sidecar beside the
            // run directory it guards.
            if name.hasPrefix(".f-"), name.hasSuffix(".owner.json"),
                values.isRegularFile == true, values.isSymbolicLink != true
            {
                recoverySidecars.append(entry)
                continue
            }
            throw TaskLocalScopeError.unexpectedArtifact(name)
        }
        for fixtureDirectory in fixtureDirectories {
            for socketDirectoryName in ["s", "c"] {
                let socketDirectory = fixtureDirectory.appendingPathComponent(
                    socketDirectoryName,
                    isDirectory: true
                )
                guard FileManager.default.fileExists(atPath: socketDirectory.path) else {
                    continue
                }
                let entries = try FileManager.default.contentsOfDirectory(
                    at: socketDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                for entry in entries {
                    let entryValues = try entry.resourceValues(forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey,
                    ])
                    guard ["s", "s.lock"].contains(entry.lastPathComponent),
                        entryValues.isDirectory != true,
                        entryValues.isSymbolicLink != true
                    else {
                        throw TaskLocalScopeError.unexpectedArtifact(entry.lastPathComponent)
                    }
                    try FileManager.default.removeItem(at: entry)
                }
                try FileManager.default.removeItem(at: socketDirectory)
            }
            for fileName in ["tmux.conf", "owner.json"] {
                let file = fixtureDirectory.appendingPathComponent(fileName)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let values = try file.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw TaskLocalScopeError.unexpectedArtifact(fileName)
                }
                try FileManager.default.removeItem(at: file)
            }
            guard
                try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path).isEmpty
            else {
                throw TaskLocalScopeError.unexpectedArtifact(
                    fixtureDirectory.lastPathComponent
                )
            }
            try FileManager.default.removeItem(at: fixtureDirectory)
        }
        for recoverySidecar in recoverySidecars {
            try FileManager.default.removeItem(at: recoverySidecar)
        }
        try FileManager.default.removeItem(at: root)
    }
}

private func cleanupTaskLocalScopeAfterFailure(_ scope: TaskLocalTestScope) {
    do {
        try scope.removeKnownArtifacts()
    } catch {
        Issue.record("task-local fixture test cleanup failed: \(error)")
    }
}

@Suite(
    "task-local fixture contender",
    .timeLimit(.minutes(1))
)
struct ParallelFixtureTests {
    @Test(
        "parameterized cases overlap with unique inherited fixtures",
        TmuxFixtureTrait(
            configuration: inMemoryFixtureConfiguration,
            transport: inMemoryFixtureTransport
        ),
        arguments: Array(0..<taskLocalCaseCount)
    )
    func parameterizedCasesOverlapWithUniqueInheritedFixtures(
        _ argument: Int
    ) async throws {
        let fixture = try currentTmuxFixture()
        let inherited = try await Task {
            try currentTmuxFixture()
        }.value
        #expect(inherited == fixture)

        let snapshot = try await taskLocalOverlap.enter(
            argument: argument,
            fixture: fixture
        )
        #expect(snapshot.argumentCount == taskLocalCaseCount)
        #expect(snapshot.endpointCount == taskLocalCaseCount)
        #expect(snapshot.tokenCount == taskLocalCaseCount)
    }

    @Test("task-local scope cleans after success and restores context")
    func taskLocalScopeCleansAfterSuccessAndRestoresContext() async throws {
        let scope = try TaskLocalTestScope()
        var cleanupRequired = true
        defer {
            if cleanupRequired { cleanupTaskLocalScopeAfterFailure(scope) }
        }
        let transport = InMemoryFixtureTransport()
        let cleanupFailures = TaskLocalCleanupFailures()

        try await withTaskLocalTmuxServer(
            configuration: scope.configuration,
            transport: transport,
            secondaryCleanupFailureSink: { failure in
                await cleanupFailures.record(failure)
            }
        ) {
            let fixture = try currentTmuxFixture()
            let inherited = try await Task { try currentTmuxFixture() }.value
            #expect(inherited == fixture)
        }

        #expect(await transport.activeFixtureCount == 0)
        #expect(await cleanupFailures.snapshot.isEmpty)
        do {
            _ = try currentTmuxFixture()
            Issue.record("task-local fixture escaped its scope")
        } catch let error as FixtureContextError {
            #expect(error == .missingFixture)
        }
        try scope.removeKnownArtifacts()
        cleanupRequired = false
    }

    @Test("task-local scope preserves a body error after cleanup")
    func taskLocalScopePreservesBodyErrorAfterCleanup() async throws {
        let scope = try TaskLocalTestScope()
        var cleanupRequired = true
        defer {
            if cleanupRequired { cleanupTaskLocalScopeAfterFailure(scope) }
        }
        let transport = InMemoryFixtureTransport()
        let cleanupFailures = TaskLocalCleanupFailures()

        do {
            try await withTaskLocalTmuxServer(
                configuration: scope.configuration,
                transport: transport,
                secondaryCleanupFailureSink: { failure in
                    await cleanupFailures.record(failure)
                }
            ) {
                _ = try currentTmuxFixture()
                throw TaskLocalBodyError.expected
            }
            Issue.record("task-local body error was discarded")
        } catch let error as TaskLocalBodyError {
            #expect(error == .expected)
        }

        #expect(await transport.activeFixtureCount == 0)
        #expect(await cleanupFailures.snapshot.isEmpty)
        try scope.removeKnownArtifacts()
        cleanupRequired = false
    }

    @Test("task-local scope cleans after cooperative cancellation")
    func taskLocalScopeCleansAfterCooperativeCancellation() async throws {
        let scope = try TaskLocalTestScope()
        var cleanupRequired = true
        defer {
            if cleanupRequired { cleanupTaskLocalScopeAfterFailure(scope) }
        }
        let transport = InMemoryFixtureTransport()
        let cleanupFailures = TaskLocalCleanupFailures()
        let bodyEntered = AsyncGate()
        let operation = Task {
            try await withTaskLocalTmuxServer(
                configuration: scope.configuration,
                transport: transport,
                secondaryCleanupFailureSink: { failure in
                    await cleanupFailures.record(failure)
                }
            ) {
                _ = try currentTmuxFixture()
                await bodyEntered.open()
                try await Task.sleep(for: .seconds(30))
            }
        }

        try await bodyEntered.wait()
        operation.cancel()
        do {
            try await operation.value
            Issue.record("task-local cancellation was discarded")
        } catch is CancellationError {
        }

        #expect(await transport.activeFixtureCount == 0)
        #expect(await cleanupFailures.snapshot.isEmpty)
        try scope.removeKnownArtifacts()
        cleanupRequired = false
    }

    @Test("task-local scope surfaces cleanup failure for a successful body")
    func taskLocalScopeSurfacesCleanupFailureForSuccessfulBody() async throws {
        let scope = try TaskLocalTestScope()
        var cleanupRequired = true
        defer {
            if cleanupRequired { cleanupTaskLocalScopeAfterFailure(scope) }
        }
        let failureReply = taskLocalReply(exitCode: 23)
        let transport = InMemoryFixtureTransport(cleanupReply: failureReply)
        let cleanupFailures = TaskLocalCleanupFailures()

        do {
            try await withTaskLocalTmuxServer(
                configuration: scope.configuration,
                transport: transport,
                secondaryCleanupFailureSink: { failure in
                    await cleanupFailures.record(failure)
                }
            ) {
                _ = try currentTmuxFixture()
            }
            Issue.record("task-local cleanup failure was discarded")
        } catch let error as FixtureCleanupError {
            #expect(error == .guardRequestFailed(failureReply))
        }

        #expect(await transport.activeFixtureCount == 1)
        #expect(await cleanupFailures.snapshot.isEmpty)
        try scope.removeKnownArtifacts()
        cleanupRequired = false
    }

    @Test("task-local body error remains primary when cleanup also fails")
    func taskLocalBodyErrorRemainsPrimaryWhenCleanupAlsoFails() async throws {
        let scope = try TaskLocalTestScope()
        var cleanupRequired = true
        defer {
            if cleanupRequired { cleanupTaskLocalScopeAfterFailure(scope) }
        }
        let failureReply = taskLocalReply(exitCode: 23)
        let transport = InMemoryFixtureTransport(cleanupReply: failureReply)
        let cleanupFailures = TaskLocalCleanupFailures()

        do {
            try await withTaskLocalTmuxServer(
                configuration: scope.configuration,
                transport: transport,
                secondaryCleanupFailureSink: { failure in
                    await cleanupFailures.record(failure)
                }
            ) {
                _ = try currentTmuxFixture()
                throw TaskLocalBodyError.expected
            }
            Issue.record("task-local body error was discarded")
        } catch let error as TaskLocalBodyError {
            #expect(error == .expected)
        }

        #expect(await transport.activeFixtureCount == 1)
        #expect(await cleanupFailures.snapshot == [.guardRequestFailed(failureReply)])
        try scope.removeKnownArtifacts()
        cleanupRequired = false
    }
}
