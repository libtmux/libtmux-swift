import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("lifecycle ownership", .serialized, .timeLimit(.minutes(5)))
struct OwnershipTests {
    private enum BodyError: Error { case failed }

    private func withServer<Result: Sendable>(
        _ body: @Sendable (Server) async throws -> Result
    ) async throws -> Result {
        let root = "/tmp/libtmux-swift-test/ownership-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let server = try Server(
            socketPath: root + "/s", tmuxExecutable: tmuxExecutablePath(),
            configurationFile: "/dev/null")
        let owner = try await server.newOwnedServer()
        let result: Swift.Result<Result, any Error>
        do { result = .success(try await owner.withValue(body)) } catch { result = .failure(error) }
        if await owner.isClosed { try FileManager.default.removeItem(atPath: root) }
        return try result.get()
    }

    @Test("all child owners close their captured IDs and borrowed objects survive")
    func children() async throws {
        try await withServer { server in
            let session = try await server.newOwnedSession(named: "owned", shell: "sleep 300")
            let window = try await server.newOwnedWindow(
                in: session.value, named: "work", shell: "sleep 300")
            let pane = try #require(
                try await server.panes().first { $0.windowID == window.value.id })
            let split = try await server.splitOwned(pane, shell: "sleep 300")
            #expect(try await server.pane(split.value.id) != nil)
            try await split.close()
            try await split.close()
            #expect(try await server.pane(split.value.id) == nil)
            try await server.rename(session.value, to: "renamed")
            try await window.close()
            #expect(try await server.window(window.value.id) == nil)
            try await session.close()
            #expect(try await server.sessions().map(\.name) == ["libtmux-bootstrap"])
        }
    }

    @Test("explicit adoption owns each existing child")
    func adoption() async throws {
        try await withServer { server in
            let session = try await server.newSession(named: "adopted", shell: "sleep 300")
            let window = try await server.newWindow(
                in: session, named: "adopted-window", shell: "sleep 300")
            let pane = try await server.splitWindow(window.window, shell: "sleep 300")
            try await server.adopt(pane).close()
            try await server.adopt(window.window).close()
            try await server.adopt(session).close()
            #expect(try await server.sessions().map(\.name) == ["libtmux-bootstrap"])
        }
    }

    @Test("scopes preserve both failures and failed cleanup can be retried")
    func combinedErrorsAndRetry() async throws {
        try await withServer { server in
            let owner = try await server.newOwnedSession(named: "retry", shell: "sleep 300")
            let original = try await server.run(
                TmuxCommand("show-options", ["-s", "-v", ownerGeneration])
            ).text
                .trimmingCharacters(in: .newlines)
            do {
                try await owner.withValue { _ in
                    _ = try await server.run(
                        TmuxCommand(
                            "set-option",
                            ["-s", ownerGeneration, String(repeating: "f", count: 32)]))
                    throw BodyError.failed
                }
                Issue.record("scope hid errors")
            } catch let failure as ResourceScopeFailure {
                #expect(failure.bodyError as? BodyError == .failed)
                #expect(failure.cleanupError == .serverRestarted)
            }
            #expect(await !owner.isClosed)
            #expect(await owner.cleanupFailure == .serverRestarted)
            #expect(try await server.session(owner.value.id) != nil)
            _ = try await server.run(TmuxCommand("set-option", ["-s", ownerGeneration, original]))
            try await owner.close()
            #expect(await owner.isClosed)
        }
    }

    @Test("cancellation cannot cancel owner teardown")
    func cancellation() async throws {
        try await withServer { server in
            let owner = try await server.newOwnedSession(named: "cancel", shell: "sleep 300")
            let (stream, signal) = AsyncStream<Void>.makeStream()
            let task = Task {
                try await owner.withValue { _ in
                    signal.yield(())
                    signal.finish()
                    try await Task.sleep(for: .seconds(300))
                }
            }
            for await _ in stream { break }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await owner.isClosed)
            #expect(try await server.session(owner.value.id) == nil)
        }
    }

    @Test(
        "invalid reserved tokens are not overwritten",
        arguments: ["", "invalid", String(repeating: "a", count: 31)])
    func invalidToken(_ token: String) async throws {
        try await withServer { server in
            let original = try await server.run(
                TmuxCommand("show-options", ["-s", "-v", ownerGeneration])
            ).text
                .trimmingCharacters(in: .newlines)
            _ = try await server.run(TmuxCommand("set-option", ["-s", ownerGeneration, token]))
            await #expect(throws: AcquisitionFailure.self) {
                try await server.newOwnedSession(named: "blocked")
            }
            #expect(try await server.sessions().count == 1)
            #expect(
                try await server.run(TmuxCommand("show-options", ["-s", "-v", ownerGeneration]))
                    .text == token + "\n")
            _ = try await server.run(TmuxCommand("set-option", ["-s", ownerGeneration, original]))
        }
    }

    @Test("find-or-create distinguishes all borrowed and owned results")
    func findHierarchy() async throws {
        try await withServer { server in
            #expect(try await !server.findOrCreate().wasCreated)
            let session = try await server.findOrCreateSession(named: "example", shell: "sleep 300")
            #expect(session.wasCreated)
            #expect(try await !server.findOrCreateSession(named: "example").wasCreated)
            let window = try await server.findOrCreateWindow(
                in: session.value, named: "worker", shell: "sleep 300")
            #expect(window.wasCreated)
            #expect(
                try await !server.findOrCreateWindow(in: session.value, named: "worker").wasCreated)
            let pane = try await server.findOrCreatePane(
                in: window.value, identity: "worker", shell: "sleep 300")
            #expect(pane.wasCreated)
            #expect(
                try await !server.findOrCreatePane(in: window.value, identity: "worker").wasCreated)
            try await session.owner?.close()
            try await server.adopt().close()
            let fresh = try await server.findOrCreate(bootstrapSession: "fresh")
            #expect(fresh.wasCreated)
            try await fresh.withValue { running async throws -> Void in
                #expect(try await !running.findOrCreate().wasCreated)
                #expect(try await running.sessions().map(\.name) == ["fresh"])
            }
        }
    }

    @Test("same-endpoint callers share an exact-name acquisition gate")
    func concurrentFind() async throws {
        try await withServer { server in
            let other = try Server(endpoint: server.endpoint, tmuxExecutable: tmuxExecutablePath())
            let results = try await withThrowingTaskGroup(of: FindOrCreate<Session>.self) { tasks in
                for index in 0..<10 {
                    let handle = index.isMultiple(of: 2) ? server : other
                    tasks.addTask {
                        try await handle.findOrCreateSession(
                            named: "concurrent", shell: "sleep 300")
                    }
                }
                var values: [FindOrCreate<Session>] = []
                for try await value in tasks { values.append(value) }
                return values
            }
            #expect(results.filter(\.wasCreated).count == 1)
            #expect(Set(results.map { $0.value.id }).count == 1)
            for result in results { try await result.owner?.close() }
        }
    }

    @Test("ambiguous windows and pane identities throw")
    func ambiguity() async throws {
        try await withServer { server in
            let session = try await server.newOwnedSession(named: "ambiguous")
            let first = try await server.newWindow(
                in: session.value, named: "duplicate", shell: "sleep 300")
            _ = try await server.newWindow(
                in: session.value, named: "duplicate", shell: "sleep 300")
            await #expect(throws: CardinalityError.multipleMatches(count: 2)) {
                try await server.findOrCreateWindow(in: session.value, named: "duplicate")
            }
            _ = try await server.splitWindow(first.window, shell: "sleep 300")
            for pane in try await server.panes().filter({ $0.windowID == first.window.id }) {
                _ = try await server.run(
                    TmuxCommand(
                        "set-option",
                        ["-p", "-t", pane.id.rawValue, "@libtmux_pane_identity", "duplicate"]))
            }
            await #expect(throws: CardinalityError.multipleMatches(count: 2)) {
                try await server.findOrCreatePane(in: first.window, identity: "duplicate")
            }
            try await session.close()
        }
    }
}

extension OwnershipTests {
    @Test(
        "creation failures preserve receipts and roll back only the created object",
        arguments: ["session", "window", "pane"],
        [ReceiptFault.exit, .cancelled, .readback, .rollback])
    private func creationFaults(kind: String, fault: ReceiptFault) async throws {
        try await withServer { fixture in
            let transport = ReceiptFaultTransport(fault: fault)
            let server = try Server(
                endpoint: fixture.endpoint, tmuxExecutable: tmuxExecutablePath(),
                transport: transport)
            let parent = try #require(try await fixture.sessions().first)
            let pane = try #require(try await fixture.panes().first)
            let before = try await fixture.snapshot()
            do {
                switch kind {
                case "session":
                    _ = try await server.newOwnedSession(named: "failure", shell: "sleep 300")
                case "window":
                    _ = try await server.newOwnedWindow(
                        in: parent, named: "failure", shell: "sleep 300")
                default: _ = try await server.splitOwned(pane, shell: "sleep 300")
                }
                Issue.record("fault disappeared")
            } catch let failure as AcquisitionFailure {
                #expect(failure.hasReceipt)
                if fault == .cancelled {
                    #expect(failure.cause as? TmuxError == .cancelled)
                    #expect(failure.commandFailure != nil)
                } else if fault == .readback {
                    #expect(
                        failure.cause as? TmuxError
                            == .decodingFailed(.invalidEncoding(rowIndex: 0)))
                } else {
                    guard case let .commandFailed(_, code, reason) = failure.cause as? TmuxError
                    else {
                        Issue.record("original status was lost")
                        return
                    }
                    #expect(code == 77)
                    #expect(reason == "injected command rejection")
                }
                if fault == .rollback {
                    #expect(
                        failure.cleanupFailure
                            == .invocationFailed(reason: "injected cleanup failure"))
                    try await failure.retryCleanup()
                } else {
                    #expect(failure.cleanupFailure == nil)
                }
            }
            let after = try await fixture.snapshot()
            #expect(after.sessions.map(\.id) == before.sessions.map(\.id))
            #expect(after.windows.map(\.id) == before.windows.map(\.id))
            #expect(after.panes.map(\.id) == before.panes.map(\.id))
        }
    }

    @Test("same numeric incarnation cannot defeat the owner generation guard")
    func numericCollision() async throws {
        try await withServer { fixture in
            let old = try await fixture.run(
                TmuxCommand("show-options", ["-s", "-v", ownerGeneration])
            ).text
                .trimmingCharacters(in: .newlines)
            try await fixture.adopt().close()
            let replacementOwner = try await fixture.newOwnedServer(bootstrapSession: "replacement")
            try await replacementOwner.withValue { replacement in
                let session = try #require(try await replacement.sessions().first)
                // The old generation now carries the replacement's numeric
                // identity at the same endpoint, simulating PID/second reuse.
                let forged = OwnershipLease(
                    server: replacement, kind: .session,
                    id: session.id.rawValue, incarnation: session.incarnation,
                    generation: old, exitObservation: nil)
                await #expect(throws: TmuxError.serverRestarted) { try await forged.close() }
                #expect(try await replacement.session(session.id) != nil)
            }
        }
    }

    @Test(
        "session names either round-trip exactly or acquisition rolls back",
        arguments: [
            "dot.name", "colon:name", "dollar$value", "back\\slash", "literal;", "hash#{pid}",
        ])
    func exactNames(_ name: String) async throws {
        try await withServer { server in
            let before = try await server.sessions().map(\.id)
            do {
                let owner = try await server.newOwnedSession(named: name, shell: "sleep 300")
                #expect(owner.value.name == name)
                try await owner.close()
            } catch let failure as AcquisitionFailure {
                #expect(failure.cleanupFailure == nil)
                #expect(failure.hasReceipt)
            }
            #expect(try await server.sessions().map(\.id) == before)
        }
    }

    @Test("fixture body cancellation still stops its daemon and removes its root")
    func fixtureCancellation() async throws {
        let (stream, signal) = AsyncStream<String>.makeStream()
        let task = Task {
            try await withTmuxServer { server in
                guard case let .socketPath(path) = server.endpoint else { return }
                signal.yield(path)
                signal.finish()
                try await Task.sleep(for: .seconds(300))
            }
        }
        var socket: String?
        for await path in stream {
            socket = path
            break
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let path = try #require(socket)
        #expect(
            !FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }
}

private enum ReceiptFault: Sendable { case exit, cancelled, readback, rollback }

private actor ReceiptFaultTransport: ProcessTransport {
    let fault: ReceiptFault
    var created = false
    var rejectedCleanup = false
    let underlying = SubprocessTransport()

    init(fault: ReceiptFault) { self.fault = fault }

    func run(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        if fault == .readback, created {
            throw .decodingFailed(.invalidEncoding(rowIndex: 0))
        }
        return try await underlying.run(
            executable: executable, arguments: arguments,
            environment: environment, perStreamOutputLimit: perStreamOutputLimit)
    }

    func runReceipted(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async -> ReceiptOutcome {
        let text = arguments.joined(separator: " ")
        if fault == .rollback, created, !rejectedCleanup, text.contains("kill-") {
            rejectedCleanup = true
            return ReceiptOutcome(
                reply: TmuxReply(standardOutput: [], standardError: [], exitCode: -1),
                failure: .invocationFailed(reason: "injected cleanup failure"))
        }
        let reply = await underlying.runReceipted(
            executable: executable, arguments: arguments,
            environment: environment, perStreamOutputLimit: perStreamOutputLimit)
        if !created, text.contains("__libtmux_ownership_"),
            text.contains("new-session") || text.contains("new-window")
                || text.contains("split-window")
        {
            created = true
            if fault == .readback { return reply }
            return ReceiptOutcome(
                reply: TmuxReply(
                    standardOutput: reply.reply.standardOutput,
                    standardError: Array("injected command rejection\n".utf8), exitCode: 77),
                failure: fault == .cancelled ? .cancelled : nil)
        }
        return reply
    }
}

extension OwnershipTests {
    @Test("a foreign startup never transfers whole-server ownership", arguments: [false, true])
    func foreignStartup(onlyCreate: Bool) async throws {
        try await withServer { fixture in
            let transport = StartupRaceTransport()
            let server = try Server(
                endpoint: fixture.endpoint, tmuxExecutable: tmuxExecutablePath(),
                transport: transport)
            let before = try await fixture.sessions().map(\.id)
            if onlyCreate {
                await #expect(throws: TmuxError.self) {
                    try await server.newOwnedServer(bootstrapSession: "race")
                }
            } else {
                let found = try await server.findOrCreate(bootstrapSession: "race")
                #expect(!found.wasCreated)
                #expect(found.owner == nil)
            }
            #expect(try await fixture.sessions().map(\.id) == before)
        }
    }

    @Test("uncertain receipts do not authorize cleanup in another numeric incarnation")
    func contradictoryReceipt() async throws {
        try await withServer { fixture in
            let parent = try #require(try await fixture.sessions().first)
            let transport = ContradictoryReceiptTransport()
            let server = try Server(
                endpoint: fixture.endpoint, tmuxExecutable: tmuxExecutablePath(),
                transport: transport)
            do {
                _ = try await server.newOwnedWindow(
                    in: parent, named: "uncertain", shell: "sleep 300")
                Issue.record("contradictory receipt was accepted")
            } catch let failure as AcquisitionFailure {
                #expect(!failure.hasReceipt)
                #expect(failure.cause as? TmuxError == .cancelled)
                #expect(
                    failure.commandFailure
                        == .commandFailed(
                            command: "new-window", exitCode: 77, reason: "receipt fault"))
            }
            #expect(try await fixture.windows(named: "uncertain").count == 1)
            #expect(await transport.cleanupCommands == 0)
        }
    }

    @Test("physical parent aliases coordinate and missing/.. fails before creation")
    func physicalPathSemantics() async throws {
        try await withServer { server in
            guard case let .socketPath(path) = server.endpoint else { return }
            let root = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: root + "/nested", withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                atPath: root + "/alias", withDestinationPath: root + "/nested")
            let alias = try Server(
                socketPath: root + "/alias/../s", tmuxExecutable: tmuxExecutablePath())
            let one = try await server.findOrCreateSession(named: "physical")
            let two = try await alias.findOrCreateSession(named: "physical")
            #expect(two.value.id == one.value.id)
            #expect(!two.wasCreated)
            let missing = try Server(
                socketPath: root + "/missing/../s", tmuxExecutable: tmuxExecutablePath())
            await #expect(throws: TmuxError.self) {
                try await missing.findOrCreateSession(named: "must-not-appear")
            }
            #expect(try await !server.hasSession("must-not-appear"))
            try await one.owner?.close()
        }
    }

    @Test("discovery reports skipped entries, bad roots and probe failures with bounds")
    func discoveryDiagnostics() async throws {
        try await withServer { server in
            guard case let .socketPath(path) = server.endpoint else { return }
            let root = (path as NSString).deletingLastPathComponent
            _ = FileManager.default.createFile(atPath: root + "/regular", contents: Data())
            try FileManager.default.createSymbolicLink(
                atPath: root + "/link", withDestinationPath: path)
            let result = try await TmuxServers.discover(
                in: [root, root + "/missing/..", "relative"], tmuxExecutable: tmuxExecutablePath())
            #expect(result.servers.map(\.socketPath) == [path])
            #expect(result.diagnostics.filter { $0.kind == .skippedEntry }.count == 2)
            #expect(
                result.diagnostics.contains {
                    $0.kind == .unreadableRoot && $0.path.hasSuffix("missing/..")
                })
            #expect(result.diagnostics.contains { $0.kind == .invalidRoot })
            let failed = try await TmuxServers.discover(in: [root], tmuxExecutable: "/bin/false")
            #expect(failed.servers.isEmpty)
            #expect(
                failed.diagnostics.contains {
                    $0.kind == .failedProbe && $0.detail.contains("commandFailed")
                })
            let truncated = try await TmuxServers.discover(
                in: [root, root], tmuxExecutable: tmuxExecutablePath(),
                limits: DiscoveryLimits(maximumRoots: 1, maximumEntries: 1))
            #expect(truncated.truncated)
            #expect(truncated.servers.count <= 1)
            #expect(truncated.diagnostics.count <= 1)
            let legacy = try JSONDecoder().decode(
                ServerDiscovery.self, from: Data(#"{"servers":[],"truncated":false}"#.utf8))
            #expect(legacy.diagnostics.isEmpty)
        }
    }

    @Test("discovery timeout is observable without swallowing caller cancellation")
    func discoveryTimeoutDiagnostic() async throws {
        let result = try await TmuxServers.discover(
            candidates: ["/unused"], probeTimeout: .milliseconds(5)
        ) { _ async throws(TmuxError) -> DiscoveredServer? in
            do {
                try await Task.sleep(for: .seconds(60))
                return nil
            } catch { throw .cancelled }
        }
        #expect(result.diagnostics.first?.kind == .timedOut)
    }
}

private actor StartupRaceTransport: ProcessTransport {
    private var probed = false
    private let underlying = SubprocessTransport()

    func run(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        try await underlying.run(
            executable: executable, arguments: arguments,
            environment: environment, perStreamOutputLimit: perStreamOutputLimit)
    }

    func runReceipted(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async -> ReceiptOutcome {
        if !probed, arguments.contains("list-sessions") {
            probed = true
            return ReceiptOutcome(
                reply: TmuxReply(
                    standardOutput: [],
                    standardError: Array("no server running on test-endpoint\n".utf8), exitCode: 1),
                failure: nil)
        }
        return await underlying.runReceipted(
            executable: executable, arguments: arguments,
            environment: environment, perStreamOutputLimit: perStreamOutputLimit)
    }
}

private actor ContradictoryReceiptTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private(set) var cleanupCommands = 0

    func run(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        try await underlying.run(
            executable: executable, arguments: arguments,
            environment: environment, perStreamOutputLimit: perStreamOutputLimit)
    }

    func runReceipted(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async -> ReceiptOutcome {
        if arguments.joined(separator: " ").contains("kill-window") { cleanupCommands += 1 }
        let result = await underlying.runReceipted(
            executable: executable, arguments: arguments,
            environment: environment, perStreamOutputLimit: perStreamOutputLimit)
        let lines = result.reply.text.split(separator: "\n").map { line -> String in
            guard line.hasPrefix("__libtmux_ownership_") else { return String(line) }
            var fields = line.split(separator: "|", omittingEmptySubsequences: false).map(
                String.init)
            fields[2] = String(Int(fields[2])! + 1)
            return fields.joined(separator: "|")
        }
        return ReceiptOutcome(
            reply: TmuxReply(
                standardOutput: Array((lines.joined(separator: "\n") + "\n").utf8),
                standardError: Array("receipt fault\n".utf8), exitCode: 77), failure: .cancelled)
    }
}

extension OwnershipTests {
    @Test("the native receipt reader retains output before an output-limit failure")
    func nativeOutputLimit() async throws {
        let result = await SubprocessTransport().runReceipted(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'receipt\\n'; head -c 4096 /dev/zero"],
            environment: ["PATH": "/usr/bin:/bin"], perStreamOutputLimit: 128)
        #expect(result.reply.text.hasPrefix("receipt\n"))
        #expect(result.reply.standardOutput.count == 128)
        #expect(result.failure == .outputLimitExceeded(perStreamBytes: 128))
    }

    @Test("native caller cancellation after receipt waits for rollback")
    func nativeCreationCancellation() async throws {
        try await withServer { fixture in
            guard case let .socketPath(path) = fixture.endpoint else { return }
            let root = (path as NSString).deletingLastPathComponent
            let marker = root + "/receipt-ready"
            let release = root + "/release"
            let shim = root + "/tmux-shim"
            let code = """
                #!/usr/bin/python3
                import os, subprocess, sys, time
                result = subprocess.run([os.environ['TEST_TMUX'], *sys.argv[1:]], capture_output=True)
                sys.stdout.buffer.write(result.stdout); sys.stdout.buffer.flush()
                sys.stderr.buffer.write(result.stderr); sys.stderr.buffer.flush()
                if b'__libtmux_ownership_' in result.stdout:
                    open(os.environ['TEST_MARKER'], 'w').close()
                    while not os.path.exists(os.environ['TEST_RELEASE']): time.sleep(0.005)
                sys.exit(result.returncode)
                """
            try code.write(toFile: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim)
            var environment = ProcessInfo.processInfo.environment
            environment["TEST_TMUX"] = tmuxExecutablePath()
            environment["TEST_MARKER"] = marker
            environment["TEST_RELEASE"] = release
            let server = try Server(
                endpoint: fixture.endpoint, tmuxExecutable: shim, environment: environment)
            let task = Task {
                try await server.newOwnedSession(named: "cancelled-native", shell: "sleep 300")
            }
            try #require(await waitUntil { FileManager.default.fileExists(atPath: marker) })
            task.cancel()
            _ = FileManager.default.createFile(atPath: release, contents: Data())
            do {
                _ = try await task.value
                Issue.record("cancellation disappeared")
            } catch let failure as AcquisitionFailure {
                #expect(failure.cause as? TmuxError == .cancelled)
                #expect(failure.hasReceipt)
                #expect(failure.cleanupFailure == nil)
            }
            #expect(try await fixture.sessions().map(\.name) == ["libtmux-bootstrap"])
        }
    }

    @Test("concurrent close calls share one cleanup attempt")
    func concurrentClose() async throws {
        let counter = CleanupCounter()
        let owner = OwnedTmux(1) { () async throws(TmuxError) in await counter.cleanup() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { try await owner.close() } }
            try await group.waitForAll()
        }
        #expect(await counter.count == 1)
        #expect(await owner.isClosed)
    }
}

private actor CleanupCounter {
    private(set) var count = 0
    func cleanup() async {
        count += 1
        try? await Task.sleep(for: .milliseconds(25))
    }
}

extension OwnershipTests {
    @Test(
        "pane identities are literal pane-local values",
        arguments: ["literal;", "#{value}", "-p", "dollar$value", "back\\slash"])
    func literalPaneIdentity(_ identity: String) async throws {
        try await withServer { server in
            let window = try #require(try await server.windows().first)
            let before = try await server.panes().map(\.id)
            do {
                let first = try await server.findOrCreatePane(
                    in: window, identity: identity, shell: "sleep 300")
                let second = try await server.findOrCreatePane(in: window, identity: identity)
                #expect(second.value.id == first.value.id)
                #expect(!second.wasCreated)
                try await first.owner?.close()
            } catch let failure as AcquisitionFailure {
                #expect(
                    failure.cause as? TmuxError
                        == .invocationFailed(
                            reason: "tmux did not retain the requested pane identity"))
                #expect(failure.cleanupFailure == nil)
                #expect(failure.hasReceipt)
            }
            #expect(try await server.panes().map(\.id) == before)
        }
    }
}

extension OwnershipTests {
    @Test("exact session names do not reuse an abbreviation")
    func exactSessionMatch() async throws {
        try await withServer { server in
            let first = try await server.newOwnedSession(named: "alphabet", shell: "sleep 300")
            let second = try await server.findOrCreateSession(named: "alpha", shell: "sleep 300")
            #expect(second.wasCreated)
            #expect(second.value.name == "alpha")
            #expect(second.value.id != first.value.id)
            try await second.owner?.close()
            try await first.close()
        }
    }

    @Test("fixture cleanup failures retain the root and original body error")
    func fixtureFailureVisibility() async throws {
        let witness = FixtureWitness()
        do {
            try await withTmuxServer { server in
                let token = try await server.run(
                    TmuxCommand("show-options", ["-s", "-v", ownerGeneration])
                ).text
                    .trimmingCharacters(in: .newlines)
                await witness.capture(server, token)
                _ = try await server.run(
                    TmuxCommand(
                        "set-option", ["-s", ownerGeneration, String(repeating: "f", count: 32)]))
                throw BodyError.failed
            }
            Issue.record("fixture swallowed cleanup failure")
        } catch let failure as FixtureCleanupFailure {
            #expect(failure.bodyError as? BodyError == .failed)
            #expect(failure.cleanupError as? TmuxError == .serverRestarted)
            #expect(FileManager.default.fileExists(atPath: failure.root))
            let (server, token) = try #require(await witness.value)
            _ = try await server.run(TmuxCommand("set-option", ["-s", ownerGeneration, token]))
            try await server.adopt().close()
            try FileManager.default.removeItem(atPath: failure.root)
        }
    }
}

private actor FixtureWitness {
    var value: (Server, String)?
    func capture(_ server: Server, _ token: String) { value = (server, token) }
}

extension OwnershipTests {
    @Test("native acquisition timeout retains its receipt and rolls back")
    func nativeCreationTimeout() async throws {
        try await withServer { fixture in
            guard case let .socketPath(path) = fixture.endpoint else { return }
            let root = (path as NSString).deletingLastPathComponent
            let shim = root + "/timeout-shim"
            let code = """
                #!/usr/bin/python3
                import os, subprocess, sys, time
                result = subprocess.run([os.environ['TEST_TMUX'], *sys.argv[1:]], capture_output=True)
                sys.stdout.buffer.write(result.stdout); sys.stdout.buffer.flush()
                sys.stderr.buffer.write(result.stderr); sys.stderr.buffer.flush()
                if b'__libtmux_ownership_' in result.stdout: time.sleep(300)
                sys.exit(result.returncode)
                """
            try code.write(toFile: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim)
            var environment = ProcessInfo.processInfo.environment
            environment["TEST_TMUX"] = tmuxExecutablePath()
            let server = try Server(
                endpoint: fixture.endpoint, tmuxExecutable: shim, environment: environment)
            do {
                _ = try await server.newOwnedSession(named: "timeout-native", shell: "sleep 300")
                Issue.record("deadline disappeared")
            } catch let failure as AcquisitionFailure {
                #expect(
                    failure.cause as? TmuxError
                        == .invocationFailed(reason: "lifecycle client exceeded ten seconds"))
                #expect(failure.hasReceipt)
                #expect(failure.cleanupFailure == nil)
            }
            #expect(try await fixture.sessions().map(\.name) == ["libtmux-bootstrap"])
        }
    }

    @Test("adoption and guarded cleanup cannot start a missing daemon")
    func noStartClients() async throws {
        try await withServer { fixture in
            let transport = NoStartWitness()
            let server = try Server(
                endpoint: fixture.endpoint, tmuxExecutable: tmuxExecutablePath(),
                transport: transport)
            let owner = try await server.newOwnedSession(named: "no-start", shell: "sleep 300")
            try await owner.close()
            let session = try #require(try await fixture.sessions().first)
            _ = try await server.adopt(session)
            #expect(await transport.nonStartingCalls == 4)
            #expect(await transport.unexpectedStartingCalls == 0)
        }
    }
}

private actor NoStartWitness: ProcessTransport {
    private let underlying = SubprocessTransport()
    private(set) var nonStartingCalls = 0
    private(set) var unexpectedStartingCalls = 0

    func run(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        try await underlying.run(
            executable: executable, arguments: arguments,
            environment: environment, perStreamOutputLimit: perStreamOutputLimit)
    }

    func runReceipted(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async -> ReceiptOutcome {
        if !arguments.contains("start-server") {
            if arguments.contains("-N") {
                nonStartingCalls += 1
            } else {
                unexpectedStartingCalls += 1
            }
        }
        return await underlying.runReceipted(
            executable: executable, arguments: arguments,
            environment: environment, perStreamOutputLimit: perStreamOutputLimit)
    }
}
