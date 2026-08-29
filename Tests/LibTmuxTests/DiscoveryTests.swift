import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("finding servers", .timeLimit(.minutes(1)))
struct DiscoveryTests {
    @Test("a running server is found in the directory its socket is in")
    func runningServerIsFound() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(path) = server.endpoint else {
                Issue.record("the fixture addresses by path")
                return
            }
            let directory = (path as NSString).deletingLastPathComponent
            let found = try await TmuxServers.discover(
                in: [directory],
                tmuxExecutable: tmuxExecutablePath()
            )
            #expect(found.servers.map(\.socketPath) == [path])
            #expect(found.servers.first?.sessionCount == 1)
            #expect(found.servers.first?.processID != nil)
        }
    }

    @Test("a running server with no sessions is found")
    func runningServerWithoutSessionsIsFound() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(path) = server.endpoint else { return }
            let directory = (path as NSString).deletingLastPathComponent
            let session = try #require(try await server.sessions().first)
            _ = try await server.setOption("exit-empty", to: "off")
            try await server.kill(session)
            #expect(try await server.isRunning())

            let found = try await TmuxServers.discover(
                in: [directory],
                tmuxExecutable: tmuxExecutablePath()
            )

            #expect(found.servers.map(\.socketPath) == [path])
            #expect(found.servers.first?.sessionCount == 0)
            #expect(found.servers.first?.processID != nil)
        }
    }

    @Test("a socket left behind by a server that exited is not reported")
    func staleSocketIsNotAServer() async throws {
        let directory = "/tmp/libtmux-swift-test/stale-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // tmux leaves the file behind when it exits, so a listing of the
        // directory is a listing of sockets rather than of servers.
        _ = FileManager.default.createFile(atPath: "\(directory)/dead", contents: Data())

        let found = try await TmuxServers.discover(
            in: [directory],
            tmuxExecutable: tmuxExecutablePath()
        )
        #expect(found.servers.isEmpty)
    }

    @Test("a directory that is not there is not an error")
    func missingDirectoryIsEmpty() async throws {
        let found = try await TmuxServers.discover(
            in: ["/tmp/libtmux-swift-test/definitely-not-here"],
            tmuxExecutable: tmuxExecutablePath()
        )
        #expect(found.servers.isEmpty)
    }

    @Test("TMUX_TMPDIR is the parent of tmux's socket directory")
    func defaultDirectoriesFollowTmux() {
        #expect(
            TmuxServers.defaultDirectories(environment: ["TMUX_TMPDIR": "/somewhere"])
                == ["/somewhere/tmux-\(getuid())"]
        )
        // tmux builds the fallback from the real user id rather than the name.
        let fallback = TmuxServers.defaultDirectories(environment: [:])
        #expect(fallback == ["/tmp/tmux-\(getuid())"])
    }

    @Test("only socket entries are probed")
    func nonSocketsAreSkipped() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socketPath) = server.endpoint else { return }
            let directory = (socketPath as NSString).deletingLastPathComponent
            _ = FileManager.default.createFile(
                atPath: "\(directory)/regular",
                contents: Data()
            )
            try FileManager.default.createDirectory(
                atPath: "\(directory)/nested",
                withIntermediateDirectories: false
            )
            let recorder = ProbeRecorder()

            let result = try await TmuxServers.discover(in: [directory]) { path in
                await recorder.record(path)
                return nil
            }

            #expect(await recorder.paths == [socketPath])
            #expect(result.servers.isEmpty)
            #expect(!result.truncated)
        }
    }

    @Test("socket probes have fixed concurrency")
    func probeConcurrencyIsBounded() async throws {
        let concurrencyLimit = 8
        let count = concurrencyLimit * 3
        let candidates = (0..<count).map { "/candidate/\($0)" }
        let meter = ProbeConcurrencyMeter()

        @Sendable func probe(_ path: String) async throws(TmuxError) -> DiscoveredServer? {
            await meter.started()
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                await meter.finished()
                throw TmuxError.cancelled
            }
            await meter.finished()
            return DiscoveredServer(socketPath: path, processID: nil, sessionCount: 1)
        }
        let result = try await TmuxServers.discover(candidates: candidates, probe: probe)

        #expect(await meter.peak == concurrencyLimit)
        #expect(result.servers.count == count)
    }

    @Test("discovery caps socket probes and reports truncation")
    func resultCeilingIsExplicit() async throws {
        let maximumCandidates = 128
        let candidates = (0...maximumCandidates).map { "/candidate/\($0)" }
        let recorder = ProbeRecorder()

        let result = try await TmuxServers.discover(candidates: candidates) { path in
            await recorder.record(path)
            return DiscoveredServer(socketPath: path, processID: nil, sessionCount: 1)
        }

        #expect(await recorder.paths.count == maximumCandidates)
        #expect(result.servers.count == maximumCandidates)
        #expect(result.truncated)
    }

    @Test("discovery stops inspecting a directory at the raw entry ceiling")
    func rawEntryInspectionIsBounded() async throws {
        let inspectionLimit = 4_096
        let entries = (0...inspectionLimit).map { "/entry/\($0)" }
        let recorder = ProbeRecorder()
        var inspected = 0

        let result = try await TmuxServers.discover(
            entries: entries,
            isSocket: { _ in
                inspected += 1
                return false
            },
            probe: { path in
                await recorder.record(path)
                return nil
            }
        )

        #expect(inspected == inspectionLimit)
        #expect(await recorder.paths.isEmpty)
        #expect(result.truncated)
    }

    @Test("one failed socket probe does not discard reachable servers")
    func probeFailuresAreSkipped() async throws {
        let candidates = ["/candidate/failed", "/candidate/running", "/candidate/stale"]

        @Sendable func probe(_ path: String) async throws(TmuxError) -> DiscoveredServer? {
            switch (path as NSString).lastPathComponent {
            case "failed": throw TmuxError.invocationFailed(reason: "probe failed")
            case "running":
                return DiscoveredServer(socketPath: path, processID: 42, sessionCount: 1)
            default: return nil
            }
        }
        let result = try await TmuxServers.discover(candidates: candidates, probe: probe)

        #expect(result.servers.map(\.socketPath) == ["/candidate/running"])
        #expect(!result.truncated)
    }

    @Test("a timed-out socket probe is skipped after its tmux client exits")
    func timedOutProbeIsSkippedAndReaped() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socketPath) = server.endpoint else { return }
            let reachable = "/candidate/reachable"
            let nonce = UUID().uuidString
            let started = "libtmux-test-discovery-started-\(nonce)"
            let blocked = "libtmux-test-discovery-blocked-\(nonce)"
            let failsafe = Task {
                try await Task.sleep(for: .seconds(3))
                try await server.signal(blocked)
            }
            defer { failsafe.cancel() }

            @Sendable func probe(
                _ path: String
            ) async throws(TmuxError) -> DiscoveredServer? {
                if path == reachable {
                    return DiscoveredServer(
                        socketPath: path,
                        processID: nil,
                        sessionCount: 1
                    )
                }
                _ = try await server.run(
                    TmuxCommand(
                        "if-shell",
                        ["-F", "1", "wait-for -S \(started); wait-for \(blocked)", ""]
                    )
                )
                return DiscoveredServer(socketPath: path, processID: nil, sessionCount: 1)
            }
            let discovery = Task {
                try await TmuxServers.discover(
                    candidates: [socketPath, reachable],
                    probeTimeout: .seconds(1),
                    probe: probe
                )
            }

            try await server.wait(for: started)
            let waitingSince = ContinuousClock.now
            let result = try await discovery.value

            #expect(result.servers.map(\.socketPath) == [reachable])
            #expect(!result.truncated)
            #expect(waitingSince.duration(to: .now) < .seconds(2))
            #expect(try await server.clients().isEmpty)
        }
    }

    @Test("cancelling discovery never returns a partial listing")
    func cancellationIsPropagated() async throws {
        let meter = ProbeConcurrencyMeter()
        @Sendable func probe(_: String) async throws(TmuxError) -> DiscoveredServer? {
            await meter.started()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                await meter.finished()
                throw TmuxError.cancelled
            }
            await meter.finished()
            return nil
        }
        let task = Task {
            try await TmuxServers.discover(candidates: ["/candidate/blocked"], probe: probe)
        }

        await meter.waitUntilStarted()
        task.cancel()
        await #expect(throws: TmuxError.cancelled) {
            _ = try await task.value
        }
    }
}

private actor ProbeRecorder {
    private(set) var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }
}

private actor ProbeConcurrencyMeter {
    private var active = 0
    private(set) var peak = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func started() {
        active += 1
        peak = max(peak, active)
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    func finished() {
        active -= 1
    }

    func waitUntilStarted() async {
        if peak > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
