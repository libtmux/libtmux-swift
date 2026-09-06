import Foundation
import Testing

@testable import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("subprocess teardown", .timeLimit(.minutes(5)))
struct TransportTeardownTests {
    @Test("cancellation reaps descendants")
    func cancellationReapsDescendants() async throws {
        let probe = try DescendantProbe()
        let operation = Task { try await probe.run() }
        defer {
            operation.cancel()
            probe.cleanUp()
        }

        try await probe.waitUntilReady()
        operation.cancel()
        await #expect(throws: TmuxError.cancelled) {
            try await operation.value
        }

        #expect(try await probe.readerCloses())
    }

    @Test("output overflow reaps descendants")
    func outputOverflowReapsDescendants() async throws {
        let probe = try DescendantProbe()
        let operation = Task { try await probe.run(perStreamOutputLimit: 16) }
        defer {
            operation.cancel()
            probe.cleanUp()
        }

        try await probe.waitUntilReady()
        try probe.releaseOutput()
        await #expect(
            throws: TmuxError.outputLimitExceeded(perStreamBytes: 16)
        ) {
            try await operation.value
        }

        #expect(try await probe.readerCloses())
    }
}

private struct DescendantProbe: Sendable {
    private let root: URL
    private let fifo: URL
    private let ready: URL
    private let release: URL
    private let processIDs: URL

    init() throws {
        root = URL(fileURLWithPath: "/tmp/libtmux-swift-test", isDirectory: true)
            .appendingPathComponent(
                "transport-teardown-\(UUID().uuidString)",
                isDirectory: true
            )
        fifo = root.appendingPathComponent("descendant.fifo")
        ready = root.appendingPathComponent("ready")
        release = root.appendingPathComponent("release")
        processIDs = root.appendingPathComponent("pids")

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let result = fifo.path.withCString { mkfifo($0, mode_t(0o600)) }
        guard result == 0 else {
            throw ProbeFailure(operation: "mkfifo", code: errno)
        }
    }

    func run(perStreamOutputLimit: Int = .max) async throws(TmuxError) -> TmuxReply {
        try await SubprocessTransport().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                Self.script,
                "libtmux-transport-probe",
                fifo.path,
                ready.path,
                processIDs.path,
                release.path,
            ],
            environment: [:],
            perStreamOutputLimit: perStreamOutputLimit
        )
    }

    func waitUntilReady() async throws {
        for _ in 0..<1_000 {
            if FileManager.default.fileExists(atPath: ready.path),
                (try? descendantProcessID()) != nil
            {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ProbeFailure(operation: "wait for descendant", code: nil)
    }

    func releaseOutput() throws {
        try Data().write(to: release)
    }

    func readerCloses() async throws -> Bool {
        for _ in 0..<200 {
            if try !hasReader() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try !hasReader()
    }

    func cleanUp() {
        if (try? hasReader()) == true,
            let processID = try? descendantProcessID()
        {
            _ = kill(processID, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func hasReader() throws -> Bool {
        let descriptor = fifo.path.withCString { open($0, O_WRONLY | O_NONBLOCK) }
        if descriptor >= 0 {
            _ = close(descriptor)
            return true
        }
        let code = errno
        guard code == ENXIO else {
            throw ProbeFailure(operation: "open FIFO", code: code)
        }
        return false
    }

    private func descendantProcessID() throws -> pid_t {
        let contents = try String(contentsOf: processIDs, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        guard lines.count == 2, let processID = pid_t(lines[1]) else {
            throw ProbeFailure(operation: "read descendant PID", code: nil)
        }
        return processID
    }

    private static let script = #"""
        /bin/sh -c 'exec 3<> "$1"; : > "$2"; while :; do read value <&3 || :; done' \
            libtmux-descendant "$1" "$2" &
        descendant=$!
        printf '%s\n%s\n' "$$" "$descendant" > "$3"
        while [ ! -e "$2" ]; do :; done
        while [ ! -e "$4" ]; do :; done
        i=0
        while [ "$i" -lt 128 ]; do
            printf x
            i=$((i + 1))
        done
        wait "$descendant"
        """#
}

private struct ProbeFailure: Error {
    let operation: String
    let code: Int32?
}
