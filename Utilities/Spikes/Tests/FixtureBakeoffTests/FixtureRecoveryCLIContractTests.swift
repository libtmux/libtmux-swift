import Foundation
import Testing

@testable import FixtureOwnerHelper
@testable import SpikeSupport
@testable import TransportBakeoff

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("Fixture recovery CLI contracts", .serialized)
struct FixtureRecoveryCLIContractTests {
    @Test("recovery results have typed canonical replies and exit statuses")
    func recoveryResultReplyContract() throws {
        let cleaned = fixtureOwnerRecoveryDisposition(for: .cleaned)
        let alreadyAbsent = fixtureOwnerRecoveryDisposition(for: .alreadyAbsent)

        #expect(cleaned.status == .success)
        #expect(cleaned.reply.mode == "recover")
        #expect(cleaned.reply.outcome == "cleaned")
        #expect(cleaned.reply.protocolVersion == 2)
        #expect(cleaned.reply.reason == nil)
        #expect(alreadyAbsent.status == .success)
        #expect(alreadyAbsent.reply.outcome == "already-absent")
    }

    @Test("recovery replies are canonical and contain no private details")
    func recoveryReplyIsCanonicalAndPrivate() throws {
        let resultBytes = try fixtureOwnerRecoveryJSONLine(
            fixtureOwnerRecoveryDisposition(for: .cleaned).reply
        )
        #expect(
            resultBytes
                == Array(
                    "{\"mode\":\"recover\",\"outcome\":\"cleaned\",\"protocolVersion\":2}\n"
                        .utf8
                )
        )

        let error = FixtureRecoveryError.filesystem(
            operation: "/private/run/token/12345",
            code: 12345
        )
        let disposition = fixtureOwnerRecoveryDisposition(for: error)
        let errorBytes = try fixtureOwnerRecoveryJSONLine(disposition.reply)
        let errorLine = String(decoding: errorBytes, as: UTF8.self)

        #expect(disposition.status == .preserved)
        #expect(
            errorLine
                == "{\"mode\":\"recover\",\"outcome\":\"preserved\",\"protocolVersion\":2,\"reason\":\"filesystem\"}\n"
        )
        #expect(!errorLine.contains("/private"))
        #expect(!errorLine.contains("12345"))
    }

    @Test(
        "recovery errors have stable outcome and exit mappings",
        arguments: [
            RecoveryErrorMapping(
                error: .artifactIdentityChanged,
                status: .rejected,
                outcome: "rejected",
                reason: "artifact-identity-changed"
            ),
            RecoveryErrorMapping(
                error: .cleanupStateUnverifiable,
                status: .preserved,
                outcome: "preserved",
                reason: "cleanup-state-unverifiable"
            ),
            RecoveryErrorMapping(
                error: .cleanupFailed(.deadlineExceeded),
                status: .preserved,
                outcome: "preserved",
                reason: "cleanup-failed"
            ),
            RecoveryErrorMapping(
                error: .invalidMarker,
                status: .rejected,
                outcome: "rejected",
                reason: "invalid-marker"
            ),
            RecoveryErrorMapping(
                error: .invalidRunDirectory,
                status: .rejected,
                outcome: "rejected",
                reason: "invalid-run-directory"
            ),
            RecoveryErrorMapping(
                error: .invalidTmuxExecutable,
                status: .rejected,
                outcome: "rejected",
                reason: "invalid-tmux-executable"
            ),
            RecoveryErrorMapping(
                error: .markerBusy,
                status: .busy,
                outcome: "busy",
                reason: "owner-lock-busy"
            ),
            RecoveryErrorMapping(
                error: .ownerCloseFailed(
                    primary: .result(.cleaned),
                    close: .systemCall(operation: "close-private", code: 5)
                ),
                status: .preserved,
                outcome: "preserved",
                reason: "owner-close-failed"
            ),
            RecoveryErrorMapping(
                error: .tmuxExecutableMismatch,
                status: .rejected,
                outcome: "rejected",
                reason: "tmux-executable-mismatch"
            ),
        ]
    )
    func recoveryErrorMapping(_ mapping: RecoveryErrorMapping) {
        let disposition = fixtureOwnerRecoveryDisposition(for: mapping.error)

        #expect(disposition.status == mapping.status)
        #expect(disposition.reply.outcome == mapping.outcome)
        #expect(disposition.reply.reason == mapping.reason)
    }

    @Test("helper parses only the exact recovery grammar")
    func helperParsesExactRecoveryGrammar() throws {
        let runDirectory = "/tmp/f-recovery-cli-parser"
        let request = try fixtureOwnerRecoveryRequest(
            arguments: ["recover", "--run-directory", runDirectory]
        )
        #expect(request.runDirectory.path == runDirectory)
        #expect(request.expectedTmuxExecutable == nil)

        let expected = "/opt/libtmux-private/bin/tmux"
        let privateRequest = try fixtureOwnerRecoveryRequest(
            arguments: [
                "recover", "--run-directory", runDirectory,
                "--expected-tmux-executable", expected,
            ]
        )
        #expect(privateRequest.runDirectory.path == runDirectory)
        #expect(privateRequest.expectedTmuxExecutable == .path(expected))
    }

    @Test(
        "helper rejects ambiguous recovery arguments",
        arguments: [
            [],
            ["recover"],
            ["recover", "--run-directory"],
            ["recover", "--run-directory", "relative/f-one"],
            ["recover", "--run-directory", "/tmp/not-a-fixture"],
            ["recover", "--run-directory", "/tmp/f-one/"],
            ["recover", "--run-directory", "/tmp//f-one"],
            ["recover", "--run-directory", "/tmp/./f-one"],
            ["recover", "--run-directory", "/tmp/../f-one"],
            ["recover", "--run-directory", "/tmp/f-one", "extra"],
            ["recover", "--run-directory", "/tmp/f-one", "--run-directory", "/tmp/f-two"],
            ["recover", "--run-directory", "/tmp/f-one", "--expected-tmux-executable", "tmux"],
            [
                "recover", "--run-directory", "/tmp/f-one", "--expected-tmux-executable",
                "/opt/tmux", "extra",
            ],
        ]
    )
    func helperRejectsAmbiguousRecoveryArguments(_ arguments: [String]) {
        #expect(throws: FixtureOwnerRecoveryRequestError.self) {
            try fixtureOwnerRecoveryRequest(arguments: arguments)
        }
    }

    @Test("helper rejects a final-component run-directory symlink")
    func helperRejectsRunDirectorySymlink() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-cli-parser-\(UUID().uuidString)")
        let target = parent.appendingPathComponent("target")
        let link = parent.appendingPathComponent("f-link")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        #expect(throws: FixtureOwnerRecoveryRequestError.self) {
            try fixtureOwnerRecoveryRequest(
                arguments: ["recover", "--run-directory", link.path]
            )
        }
    }

    @Test("helper recovery injects the selected Swift subprocess transport")
    func helperUsesSelectedRecoveryTransport() async throws {
        #expect(fixtureOwnerRecoveryTransport() is SwiftSubprocessTransport)

        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("f-absent-\(UUID().uuidString)")
        let request = try fixtureOwnerRecoveryRequest(
            arguments: ["recover", "--run-directory", runDirectory.path]
        )
        let probe = RecoveryCLIInvocationProbe()
        let disposition = await fixtureOwnerRecover(
            request: request,
            transport: probe
        )

        #expect(disposition.status == .success)
        #expect(disposition.reply.outcome == "already-absent")
        #expect(await probe.invocationCount == 0)
    }

    @Test("launched helper returns canonical recovery results")
    func launchedHelperReturnsCanonicalRecoveryResults() async throws {
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("f-helper-absent-\(UUID().uuidString)")
        let reply = try await runRecoveryHelper(
            executable: recoveryHelperExecutablePath(),
            arguments: ["recover", "--run-directory", runDirectory.path]
        )

        #expect(reply.termination == .exited(0))
        #expect(reply.standardError.isEmpty)
        #expect(
            reply.standardOutput
                == Array(
                    "{\"mode\":\"recover\",\"outcome\":\"already-absent\",\"protocolVersion\":2}\n"
                        .utf8
                )
        )
    }

    @Test("launched helper rejects invalid recovery grammar with JSON")
    func launchedHelperRejectsInvalidRecoveryGrammar() async throws {
        let reply = try await runRecoveryHelper(
            executable: recoveryHelperExecutablePath(),
            arguments: ["recover", "--all"]
        )

        #expect(reply.termination == .exited(2))
        #expect(reply.standardError.isEmpty)
        #expect(
            reply.standardOutput
                == Array(
                    "{\"mode\":\"recover\",\"outcome\":\"rejected\",\"protocolVersion\":2,\"reason\":\"invalid-arguments\"}\n"
                        .utf8
                )
        )
    }

    @Test(
        "launched helper reauthenticates its executable",
        arguments: [
            RecoveryHelperMutation.symlink,
            .groupWritable,
            .otherWritable,
            .wrongBasename,
        ]
    )
    func launchedHelperReauthenticatesExecutable(
        _ mutation: RecoveryHelperMutation
    ) async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-helper-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let basename =
            mutation == .wrongBasename
            ? "not-fixture-owner-helper"
            : "fixture-owner-helper"
        let candidate = parent.appendingPathComponent(basename)
        if mutation == .symlink {
            try FileManager.default.createSymbolicLink(
                atPath: candidate.path,
                withDestinationPath: recoveryHelperExecutablePath()
            )
        } else {
            try writeExecutable(
                Array(
                    try Data(
                        contentsOf: URL(
                            fileURLWithPath: try recoveryHelperExecutablePath()
                        ))),
                to: candidate,
                permissions: mutation.permissions
            )
        }

        let reply = try await runRecoveryHelper(
            executable: candidate.path,
            arguments: [
                "recover", "--run-directory",
                "/tmp/f-helper-self-auth",
            ]
        )

        #expect(reply.termination == .exited(2))
        #expect(reply.standardError.isEmpty)
        #expect(
            reply.standardOutput
                == Array(
                    "{\"mode\":\"recover\",\"outcome\":\"rejected\",\"protocolVersion\":2,\"reason\":\"helper-authentication-failed\"}\n"
                        .utf8
                )
        )
    }

    @Test("helper executable authentication rejects a different owner")
    func helperExecutableAuthenticationRejectsDifferentOwner() throws {
        let helper = try recoveryHelperExecutablePath()
        #expect(
            fixtureOwnerRecoveryExecutableIsAuthenticated(
                at: helper,
                effectiveUserID: geteuid()
            )
        )
        #expect(
            !fixtureOwnerRecoveryExecutableIsAuthenticated(
                at: helper,
                effectiveUserID: geteuid() &+ 1
            )
        )
    }

    @Test("recovery script is marker-blind and clears the environment")
    func recoveryScriptIsMarkerBlindAndClearsEnvironment() async throws {
        let scope = try RecoveryScriptScope.create()
        defer { scope.remove() }
        try scope.createMarkerBlindnessTraps()
        let helper = try scope.createHelper(
            outcome: "cleaned",
            status: 0
        )

        let reply = try await runRecoveryScript(
            arguments: ["--run-directory", scope.runDirectory.path],
            helper: helper
        )

        #expect(reply.termination == .exited(0))
        #expect(reply.standardError.isEmpty)
        #expect(
            reply.standardOutput
                == Array(
                    "{\"mode\":\"recover\",\"outcome\":\"cleaned\",\"protocolVersion\":2}\n"
                        .utf8
                )
        )
        let capture = try String(contentsOf: scope.capture, encoding: .utf8)
        #expect(
            capture.contains(
                "ARG:recover\nARG:--run-directory\nARG:\(scope.runDirectory.path)\n"
            )
        )
        #expect(capture.contains("ENV:LC_ALL=C\n"))
        #expect(capture.contains("ENV:PATH=/usr/bin:/bin\n"))
        #expect(!capture.contains("HOME="))
        #expect(!capture.contains("TMUX="))
        #expect(!capture.contains("TMUX_PANE="))
        #expect(!capture.contains("TMPDIR="))
        #expect(!capture.contains("DEVELOPER_DIR="))
        #expect(!capture.contains("SDKROOT="))
    }

    @Test(
        "recovery script rejects ambiguous public grammar",
        arguments: [
            [],
            ["--all"],
            ["--run-directory"],
            ["--run-directory", "relative/f-one"],
            ["--run-directory", "/tmp/not-a-fixture"],
            ["--run-directory", "/tmp/f-one/"],
            ["--run-directory", "/tmp//f-one"],
            ["--run-directory", "/tmp/./f-one"],
            ["--run-directory", "/tmp/../f-one"],
            ["--run-directory", "/tmp/f-one", "extra"],
            ["--run-directory", "/tmp/f-one", "--run-directory", "/tmp/f-two"],
        ]
    )
    func recoveryScriptRejectsAmbiguousGrammar(
        _ arguments: [String]
    ) async throws {
        let scope = try RecoveryScriptScope.create(createRunDirectory: false)
        defer { scope.remove() }
        let helper = try scope.createHelper(outcome: "cleaned", status: 0)

        let reply = try await runRecoveryScript(
            arguments: arguments,
            helper: helper
        )

        #expect(reply.termination == .exited(2))
        #expect(reply.standardError.isEmpty)
        #expect(
            reply.standardOutput
                == Array(
                    "{\"mode\":\"recover\",\"outcome\":\"rejected\",\"protocolVersion\":2,\"reason\":\"invalid-arguments\"}\n"
                        .utf8
                )
                || reply.standardOutput
                    == Array(
                        "{\"mode\":\"recover\",\"outcome\":\"rejected\",\"protocolVersion\":2,\"reason\":\"invalid-run-directory\"}\n"
                            .utf8
                    )
        )
        #expect(!FileManager.default.fileExists(atPath: scope.capture.path))
    }

    @Test(
        "recovery script rejects unauthenticated helpers",
        arguments: RecoveryScriptHelperMutation.allCases
    )
    func recoveryScriptRejectsUnauthenticatedHelper(
        _ mutation: RecoveryScriptHelperMutation
    ) async throws {
        let scope = try RecoveryScriptScope.create(createRunDirectory: false)
        defer { scope.remove() }
        let helper: String?
        switch mutation {
        case .missing:
            helper = nil
        case .relative:
            helper = "fixture-owner-helper"
        case .wrongBasename:
            let candidate = scope.parent.appendingPathComponent("wrong-helper")
            helper = try scope.createHelper(
                at: candidate,
                outcome: "cleaned",
                status: 0
            )
        case .symlink:
            let target = scope.parent.appendingPathComponent("helper-target")
            _ = try scope.createHelper(
                at: target,
                outcome: "cleaned",
                status: 0
            )
            try FileManager.default.createSymbolicLink(
                at: scope.helper,
                withDestinationURL: target
            )
            helper = scope.helper.path
        case .directory:
            try FileManager.default.createDirectory(
                at: scope.helper,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o755]
            )
            helper = scope.helper.path
        case .nonExecutable:
            helper = try scope.createHelper(
                at: scope.helper,
                outcome: "cleaned",
                status: 0,
                permissions: 0o644
            )
        case .groupWritable:
            helper = try scope.createHelper(
                at: scope.helper,
                outcome: "cleaned",
                status: 0,
                permissions: 0o775
            )
        case .otherWritable:
            helper = try scope.createHelper(
                at: scope.helper,
                outcome: "cleaned",
                status: 0,
                permissions: 0o757
            )
        }

        let reply = try await runRecoveryScript(
            arguments: ["--run-directory", scope.runDirectory.path],
            helper: helper
        )

        #expect(reply.termination == .exited(2))
        #expect(reply.standardError.isEmpty)
        #expect(
            reply.standardOutput
                == Array(
                    "{\"mode\":\"recover\",\"outcome\":\"rejected\",\"protocolVersion\":2,\"reason\":\"helper-authentication-failed\"}\n"
                        .utf8
                )
        )
    }

    @Test("recovery script rejects a final-component run symlink")
    func recoveryScriptRejectsRunSymlink() async throws {
        let scope = try RecoveryScriptScope.create(createRunDirectory: false)
        defer { scope.remove() }
        let target = scope.parent.appendingPathComponent("target")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: scope.runDirectory,
            withDestinationURL: target
        )
        let helper = try scope.createHelper(outcome: "cleaned", status: 0)

        let reply = try await runRecoveryScript(
            arguments: ["--run-directory", scope.runDirectory.path],
            helper: helper
        )

        #expect(reply.termination == .exited(2))
        #expect(reply.standardError.isEmpty)
        #expect(
            reply.standardOutput
                == Array(
                    "{\"mode\":\"recover\",\"outcome\":\"rejected\",\"protocolVersion\":2,\"reason\":\"invalid-run-directory\"}\n"
                        .utf8
                )
        )
        #expect(!FileManager.default.fileExists(atPath: scope.capture.path))
    }

    @Test("launched helper reports a busy owner lock with status 75")
    func launchedHelperReportsBusyOwnerLock() async throws {
        let scope = try RecoveryBusyScope.create()
        defer { scope.remove() }

        let reply = try await runRecoveryHelper(
            executable: recoveryHelperExecutablePath(),
            arguments: [
                "recover", "--run-directory", scope.runDirectory.path,
            ]
        )

        #expect(reply.termination == .exited(75))
        #expect(reply.standardError.isEmpty)
        #expect(
            reply.standardOutput
                == Array(
                    "{\"mode\":\"recover\",\"outcome\":\"busy\",\"protocolVersion\":2,\"reason\":\"owner-lock-busy\"}\n"
                        .utf8
                )
        )
    }

    @Test(
        "recovery script preserves helper JSON and status",
        arguments: RecoveryScriptPassThroughCase.all
    )
    func recoveryScriptPreservesHelperReply(
        _ passthrough: RecoveryScriptPassThroughCase
    ) async throws {
        let scope = try RecoveryScriptScope.create(createRunDirectory: false)
        defer { scope.remove() }
        let helper = try scope.createHelper(
            jsonLine: passthrough.jsonLine,
            status: passthrough.status
        )

        let reply = try await runRecoveryScript(
            arguments: ["--run-directory", scope.runDirectory.path],
            helper: helper
        )

        #expect(reply.termination == .exited(passthrough.status))
        #expect(reply.standardError.isEmpty)
        #expect(reply.standardOutput == Array(passthrough.jsonLine.utf8))
    }

    @Test("recovery script contains no marker reads or fixture scans")
    func recoveryScriptIsExactTargetOnly() throws {
        let source = try String(contentsOf: recoveryScriptURL, encoding: .utf8)

        #expect(!source.contains("owner.json"))
        #expect(!source.contains(".owner"))
        #expect(!source.contains("--all"))
        #expect(!source.contains("find "))
    }
}

struct RecoveryErrorMapping: Sendable, CustomTestStringConvertible {
    let error: FixtureRecoveryError
    let status: FixtureOwnerRecoveryExitStatus
    let outcome: String
    let reason: String

    var testDescription: String { reason }
}

private actor RecoveryCLIInvocationProbe: ProcessTransport {
    private(set) var invocationCount = 0

    func run(_ request: ProcessRequest) async throws -> ProcessReply {
        invocationCount += 1
        return ProcessReply(
            standardOutput: [],
            standardError: [],
            termination: .exited(1)
        )
    }
}

enum RecoveryHelperMutation: String, Sendable, CustomTestStringConvertible {
    case groupWritable
    case otherWritable
    case symlink
    case wrongBasename

    var testDescription: String { rawValue }

    var permissions: mode_t {
        switch self {
        case .groupWritable:
            0o775
        case .otherWritable:
            0o757
        case .symlink, .wrongBasename:
            0o755
        }
    }
}

enum RecoveryScriptHelperMutation: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case directory
    case groupWritable
    case missing
    case nonExecutable
    case otherWritable
    case relative
    case symlink
    case wrongBasename

    var testDescription: String { rawValue }
}

struct RecoveryScriptPassThroughCase: Sendable, CustomTestStringConvertible {
    let jsonLine: String
    let status: Int32

    var testDescription: String { "status-\(status)" }

    static let all = [
        Self(
            jsonLine:
                "{\"mode\":\"recover\",\"outcome\":\"already-absent\",\"protocolVersion\":2}\n",
            status: 0
        ),
        Self(
            jsonLine:
                "{\"mode\":\"recover\",\"outcome\":\"preserved\",\"protocolVersion\":2,\"reason\":\"cleanup-state-unverifiable\"}\n",
            status: 1
        ),
        Self(
            jsonLine:
                "{\"mode\":\"recover\",\"outcome\":\"rejected\",\"protocolVersion\":2,\"reason\":\"invalid-run-directory\"}\n",
            status: 2
        ),
        Self(
            jsonLine:
                "{\"mode\":\"recover\",\"outcome\":\"busy\",\"protocolVersion\":2,\"reason\":\"owner-lock-busy\"}\n",
            status: 75
        ),
    ]
}

private enum RecoveryCLIContractError: Error {
    case helperUnavailable
}

private func recoveryHelperExecutablePath() throws -> String {
    guard
        let path = ProcessInfo.processInfo.environment[
            "LIBTMUX_FIXTURE_OWNER_HELPER"
        ],
        path.hasPrefix("/"),
        URL(fileURLWithPath: path).standardizedFileURL.path == path
    else {
        throw RecoveryCLIContractError.helperUnavailable
    }
    return path
}

/// Foundation opens a destination without `O_CLOEXEC`, so any process forked
/// while it writes inherits that descriptor and keeps it past its own `exec`.
/// The new file then stays "text file busy" for that process's whole lifetime,
/// which no exec retry can outlast.
private func writeExecutable(
    _ bytes: [UInt8],
    to destination: URL,
    permissions: mode_t
) throws {
    let descriptor = destination.path.withCString {
        open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    }
    guard descriptor >= 0 else {
        throw RecoveryCLIContractError.helperUnavailable
    }
    var written = 0
    while written < bytes.count {
        let count = bytes[written...].withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress, buffer.count)
        }
        if count < 0 {
            if errno == EINTR { continue }
            _ = close(descriptor)
            throw RecoveryCLIContractError.helperUnavailable
        }
        written += count
    }
    guard fchmod(descriptor, permissions) == 0, close(descriptor) == 0 else {
        throw RecoveryCLIContractError.helperUnavailable
    }
}

private func runRecoveryHelper(
    executable: String,
    arguments: [String]
) async throws -> ProcessReply {
    let request = try ProcessRequest(
        executable: .path(executable),
        arguments: arguments,
        environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin"],
        workingDirectory: nil,
        outputPolicy: .limited(maxBytesPerStream: 16 * 1024)
    )
    // A copied helper is reported busy while any concurrently forked child in
    // this process still holds the write descriptor the copy opened, so exec
    // races other suites rather than the code under test.
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while ContinuousClock.now < deadline {
        do {
            return try await DirectSpawnTransport().run(request)
        } catch ProcessInvocationError.spawnFailed(code: ETXTBSY) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    return try await DirectSpawnTransport().run(request)
}

private let recoveryScriptURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Scripts/recover-fixture.sh")

private struct RecoveryScriptScope {
    let parent: URL
    let runDirectory: URL
    let helper: URL
    let capture: URL

    static func create(createRunDirectory: Bool = true) throws -> Self {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let runDirectory = parent.appendingPathComponent("f-script")
        if createRunDirectory {
            try FileManager.default.createDirectory(
                at: runDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let helper = parent.appendingPathComponent("fixture-owner-helper")
        return Self(
            parent: parent,
            runDirectory: runDirectory,
            helper: helper,
            capture: URL(fileURLWithPath: "\(helper.path).capture")
        )
    }

    func createMarkerBlindnessTraps() throws {
        try createFIFO(at: runDirectory.appendingPathComponent("owner.json"))
        try createFIFO(
            at: parent.appendingPathComponent(".f-script.owner.json")
        )
        let decoy = parent.appendingPathComponent("f-decoy")
        try FileManager.default.createDirectory(
            at: decoy,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try createFIFO(at: decoy.appendingPathComponent("owner.json"))
    }

    private func createFIFO(at fifo: URL) throws {
        let result = fifo.path.withCString { pointer in
            mkfifo(pointer, 0o600)
        }
        guard result == 0 else {
            throw RecoveryCLIContractError.helperUnavailable
        }
    }

    func createHelper(
        outcome: String,
        status: Int32
    ) throws -> String {
        try createHelper(at: helper, outcome: outcome, status: status)
    }

    func createHelper(
        at destination: URL,
        outcome: String,
        status: Int32,
        permissions: mode_t = 0o755
    ) throws -> String {
        try createHelper(
            at: destination,
            jsonLine: "{\"mode\":\"recover\",\"outcome\":\"\(outcome)\",\"protocolVersion\":2}\n",
            status: status,
            permissions: permissions
        )
    }

    func createHelper(
        jsonLine: String,
        status: Int32
    ) throws -> String {
        try createHelper(at: helper, jsonLine: jsonLine, status: status)
    }

    private func createHelper(
        at destination: URL,
        jsonLine: String,
        status: Int32,
        permissions: mode_t = 0o755
    ) throws -> String {
        let escapedJSON = jsonLine.dropLast()
            .replacingOccurrences(of: "'", with: "'\\''")
        let helperSource = """
            #!/bin/sh
            {
                printf 'ARG:%s\\n' "$@"
                /usr/bin/env | /usr/bin/sed 's/^/ENV:/'
            } > "${0}.capture"
            printf '%s\\n' '\(escapedJSON)'
            exit \(status)
            """
        try writeExecutable(
            Array(helperSource.utf8),
            to: destination,
            permissions: permissions
        )
        return destination.path
    }

    func remove() {
        try? FileManager.default.removeItem(at: parent)
    }
}

private struct RecoveryBusyScope {
    let parent: URL
    let runDirectory: URL
    let markerDescriptor: Int32

    static func create() throws -> Self {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-busy-\(UUID().uuidString)")
        let runDirectory = parent.appendingPathComponent("f-busy")
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = runDirectory.appendingPathComponent("owner.json")
        let descriptor = marker.path.withCString { pointer in
            open(pointer, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            throw RecoveryCLIContractError.helperUnavailable
        }
        let record = Array(
            "{\"ownerProcessIdentifier\":\(getpid()),\"token\":\"7A67F268-C6CB-42C5-863B-C9CF9E80DF9A\",\"version\":1}\n"
                .utf8
        )
        let written = record.withUnsafeBytes { bytes in
            write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == record.count,
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            _ = close(descriptor)
            throw RecoveryCLIContractError.helperUnavailable
        }
        return Self(
            parent: parent,
            runDirectory: runDirectory,
            markerDescriptor: descriptor
        )
    }

    func remove() {
        _ = flock(markerDescriptor, LOCK_UN)
        _ = close(markerDescriptor)
        try? FileManager.default.removeItem(at: parent)
    }
}

private func runRecoveryScript(
    arguments: [String],
    helper: String?
) async throws -> ProcessReply {
    var environment = [
        "HOME": "/private/home",
        "PATH": "/hostile/bin",
        "TMUX": "private-tmux",
        "TMUX_PANE": "%private",
        "TMPDIR": "/private/tmp",
        "DEVELOPER_DIR": "/private/developer",
        "SDKROOT": "/private/sdk",
    ]
    if let helper {
        environment["LIBTMUX_FIXTURE_OWNER_HELPER"] = helper
    }
    return try await DirectSpawnTransport().run(
        ProcessRequest(
            executable: .path(recoveryScriptURL.path),
            arguments: arguments,
            environment: environment,
            workingDirectory: nil,
            outputPolicy: .limited(maxBytesPerStream: 16 * 1024)
        )
    )
}
