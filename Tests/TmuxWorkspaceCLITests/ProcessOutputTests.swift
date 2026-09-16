import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import TmuxWorkspaceCLI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("workspace process output", .serialized, .timeLimit(.minutes(1)))
struct ProcessOutputTests {
    @Test(
        "cancelled loads retain one terminal record on writable output", arguments: [false, true])
    func cancelledResult(_ append: Bool) async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let script = root.appendingPathComponent("cancel-producer")
            try Data("printf first-data; exec sleep 30".utf8).write(to: script)
            let file = root.appendingPathComponent("cancel.json")
            try Data(
                Value.object([
                    "session_name": .string("cancelled"),
                    "before_script": .string("/bin/sh '\(script.path)'"),
                    "windows": .array([.object(["panes": .array([.null])])]),
                ]).encoded().utf8
            ).write(to: file)
            let captured = ProcessOutput(gate: root.appendingPathComponent("unused-release"))
            var environment = ProcessInfo.processInfo.environment
            environment["LIBTMUX_TMUX_BIN"] = server.tmuxExecutable
            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first)
            let pane = try #require(snapshot.panes.first)
            environment["TMUX"] =
                "\(socket),\(snapshot.incarnation.processID),\(session.id.rawValue.dropFirst())"
            environment["TMUX_PANE"] = pane.id.rawValue
            let context = CLIContext(
                directory: root, environment: environment,
                output: { text in
                    try Task.checkCancellation()
                    await captured.record(text)
                },
                error: { text in
                    try Task.checkCancellation()
                    try await captured.diagnostic(text)
                })
            let task = Task {
                await WorkspaceCLI.run(
                    ["load", file.path, append ? "--append" : "-d", "-S", socket, "--ndjson"],
                    context: context)
            }
            for _ in 0..<300 where !(await captured.released) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await captured.released)
            task.cancel()
            #expect(await task.value == 130)
            let records = try await captured.records.map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            let failed = records.filter { $0["event"] as? String == "failed" }
            #expect(failed.count == 1)
            // Event fields sit at the top level of the record, not nested
            // under a `data` key.
            let data = try #require(failed.first)
            #expect(data["status"] as? String == (append ? "partial" : "error"))
            if append {
                #expect(
                    (data["retained_state"] as? [String: Any])?["session_id"] as? String
                        == session.id.rawValue)
            }
            #expect(try await server.sessions().map(\.id) == snapshot.sessions.map(\.id))
        }
    }

    @Test(
        "captured shell output releases the running Python bridge",
        .enabled(if: ProcessInfo.processInfo.environment["TMUX_WORKSPACE_TEST_PYTHON"] != nil),
        arguments: [[], ["--json"], ["--ndjson"]])
    func liveShell(_ mode: [String]) async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let gate = root.appendingPathComponent("shell-release")
            let captured = ProcessOutput(gate: gate)
            let session = try await server.sessions()[0]
            var environment = ProcessInfo.processInfo.environment
            environment["LIBTMUX_TMUX_BIN"] = server.tmuxExecutable
            environment["TMUX_WORKSPACE_PYTHON"] = environment["TMUX_WORKSPACE_TEST_PYTHON"]
            environment["RELEASE"] = gate.path
            let context = CLIContext(
                directory: root, environment: environment,
                output: { text in
                    if mode.isEmpty {
                        try await captured.append(text, stream: "stdout")
                    } else {
                        await captured.record(text)
                    }
                },
                error: { text in
                    if mode.isEmpty {
                        try await captured.append(text, stream: "stderr")
                    } else {
                        try await captured.diagnostic(text)
                    }
                })
            let code = """
                import os, sys, time
                print('first-data', end='', flush=True)
                while not os.path.isfile(os.environ['RELEASE']): time.sleep(0.01)
                print(' complete', flush=True)
                print('second\\trow', flush=True)
                print('\\x1b[31mred', flush=True)
                print('diagnostic\\tline', file=sys.stderr, flush=True)
                """
            let task = Task {
                await WorkspaceCLI.run(
                    ["shell", session.name, "-S", socket, "--code", "--no-startup", "-c", code]
                        + mode,
                    context: context)
            }
            let deadline = Task {
                try await Task.sleep(for: .seconds(5))
                task.cancel()
            }
            let status = await task.value
            deadline.cancel()
            #expect(status == 0)
            #expect(await captured.released)
            #expect(
                await captured.stdout.hasSuffix(
                    "first-data complete\nsecond\trow\n"
                        + (mode.isEmpty ? "\\u001b" : "\u{1b}") + "[31mred\n"))
            #expect(await captured.stderr == "diagnostic\tline\n")
            if !mode.isEmpty {
                let records = await captured.records
                let value = try #require(
                    try JSONSerialization.jsonObject(with: Data(records.joined().utf8))
                        as? [String: Any])
                #expect(value["stdout"] as? String == (await captured.stdout))
                #expect(value["stderr"] as? String == (await captured.stderr))
            }
        }
    }

    @Test("stream decoding preserves split scalars and invalid UTF-8")
    func decoding() throws {
        let vectors: [[UInt8]] = [
            Array("plain\r\n☃🦊\n\nlast".utf8),
            [0xE0, 0x80, 0x80, 0xED, 0xA0, 0x80, 0xF4, 0x90, 0x80, 0x80],
            [0xF0, 0x90, 0x80], [0xE2, 0x98], [0xC2], [0xC0, 0xAF, 0xFF],
            [0xE2, 0x41, 0x80, 0xF0, 0x90, 0x41],
        ]
        for bytes in vectors {
            for split in 0...bytes.count {
                var output = UTF8Output()
                var streamed = try output.append(Data(bytes[..<split]))
                streamed += try output.append(Data(bytes[split...]))
                streamed += try output.append(Data(), finished: true)
                #expect(streamed == String(decoding: bytes, as: UTF8.self))
                #expect(streamed == output.value)
            }
            var output = UTF8Output()
            var streamed = ""
            for byte in bytes { streamed += try output.append(Data([byte])) }
            streamed += try output.append(Data(), finished: true)
            #expect(streamed == String(decoding: bytes, as: UTF8.self))
        }
        var partial = UTF8Output()
        #expect(try partial.append(Data([0x41, 0xE2])) == "A")
        #expect(try partial.append(Data([0x98])) == "")
        #expect(try partial.append(Data([0x83])) == "☃")
    }

    @Test("child formatting preserves lines and tabs across individual bytes")
    func childFormatting() throws {
        let input = "first\n\t☃\r\u{1b}[31m\u{7f}last\n"
        var output = UTF8Output()
        var text = ""
        for byte in input.utf8 {
            text += Presenter.sanitizeChildOutput(try output.append(Data([byte])))
        }
        text += Presenter.sanitizeChildOutput(try output.append(Data(), finished: true))
        #expect(text == "first\n\t☃\\u000d\\u001b[31m\\u007flast\n")
        #expect(Presenter.sanitize("first\n\tlast") == "first\\u000a\\u0009last")
    }

    @Test("child output stays serialized across suspended sink writes")
    func serializedSink() async throws {
        let sink = SuspendedSink()
        let context = try context()
        let result = try await ProcessCommands.run(
            [
                "/bin/sh", "-c",
                "i=0; while [ $i -lt 5000 ]; do printf 'out☃'; printf 'err🦊' >&2; i=$((i+1)); done",
            ],
            context: context
        ) { text, stream in try await sink.append(text, stream: stream) }
        #expect(result.code == 0)
        #expect(result.output == String(repeating: "out☃", count: 5000))
        #expect(result.error == String(repeating: "err🦊", count: 5000))
        #expect(await sink.stdout == result.output)
        #expect(await sink.stderr == result.error)
        #expect(await sink.maximum == 1)
    }

    @Test("sink failures stop a child with its other pipe still open")
    func failedSink() async throws {
        let task = Task {
            try await ProcessCommands.run(
                ["/bin/sh", "-c", "printf ready >&2; exec sleep 30"], context: try context()
            ) { _, _ in throw CLIError("test_sink", "Sink refused output.") }
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(3))
            task.cancel()
        }
        defer { deadline.cancel() }
        do {
            _ = try await task.value
            Issue.record("A failed sink must fail the process operation.")
        } catch {
            #expect((error as? CLIError)?.code == "test_sink")
        }
    }

    @Test("each captured stream accepts its limit and refuses overflow")
    func outputLimit() throws {
        var output = UTF8Output()
        let chunk = Data(repeating: 0x61, count: 1_048_576)
        #expect(try output.append(chunk).utf8.count == chunk.count)
        #expect(throws: (any Error).self) { try output.append(Data([0x62])) }
        #expect(output.value.utf8.count == chunk.count)
    }

    @Test("a stopped output reader cannot prevent child cancellation")
    func stoppedReader() async throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        defer {
            _ = close(descriptors[0])
            _ = close(descriptors[1])
        }
        for descriptor in descriptors {
            try #require(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0)
        }
        let writer = try NonblockingLineWriter(fileDescriptor: descriptors[1])
        let padding = [UInt8](repeating: 0x78, count: 4096)
        var full = false
        for _ in 0..<1024 {
            let count = padding.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
            if count < 0 {
                full = errno == EAGAIN || errno == EWOULDBLOCK
                break
            }
        }
        try #require(full)
        let receipt = ProcessReceipt()
        let task = Task {
            try await ProcessCommands.run(
                ["/bin/sh", "-c", "printf '%s\\n' $$; exec /usr/bin/yes output"],
                context: try context()
            ) { text, stream in
                if stream == "stdout" {
                    await receipt.writing(text)
                    switch await writer.write(text, newline: false) {
                    case .written: break
                    case .cancelled: throw CancellationError()
                    default: throw CLIError("test_pipe", "Test pipe failed.")
                    }
                }
            }
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(3))
            task.cancel()
        }
        defer { deadline.cancel() }
        for _ in 0..<300 where !(await receipt.ready) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await receipt.ready)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must fail a blocked output operation.")
        } catch { #expect(error is CancellationError) }
        let pid = try #require(await receipt.pid)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test(
        "bootstrap output releases a waiting producer before it exits",
        arguments: [[], ["--json"], ["--ndjson"]])
    func liveBootstrap(_ mode: [String]) async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let gate = root.appendingPathComponent("release")
            let script = root.appendingPathComponent("producer")
            try Data(
                """
                printf 'first-data'
                while [ ! -f "$RELEASE" ]; do sleep 0.01; done
                printf '\\r\\n\\342\\230\\203\\n\\nlast'
                printf 'diagnostic\\r\\n' >&2
                """.utf8
            ).write(to: script)
            let file = root.appendingPathComponent("input.json")
            try Data(
                Value.object([
                    "session_name": .string("streamed"),
                    "before_script": .string("/bin/sh '\(script.path)'"),
                    "windows": .array([.object(["panes": .array([.null])])]),
                ]).encoded().utf8
            ).write(to: file)
            let captured = ProcessOutput(gate: gate)
            var environment = ProcessInfo.processInfo.environment
            environment["LIBTMUX_TMUX_BIN"] = server.tmuxExecutable
            environment["RELEASE"] = gate.path
            let context = CLIContext(
                directory: root, environment: environment,
                output: { await captured.record($0) },
                error: { try await captured.diagnostic($0) },
                rawOutput: { try await captured.append($0, stream: "stdout") },
                rawError: { try await captured.append($0, stream: "stderr") })
            let task = Task {
                await WorkspaceCLI.run(
                    ["load", file.path, "-d", "-S", socket, "--no-progress"] + mode,
                    context: context)
            }
            let deadline = Task {
                try await Task.sleep(for: .seconds(3))
                task.cancel()
            }
            let code = await task.value
            deadline.cancel()
            #expect(code == 0)
            #expect(await captured.released)
            #expect(await captured.stdout == "first-data\r\n☃\n\nlast")
            #expect(await captured.stderr == "diagnostic\r\n")
            #expect(try await server.sessions().contains { $0.name == "streamed" })
        }
    }

    @Test(
        "logging filters bootstrap diagnostics without hiding its result",
        arguments: ["warning", "error"])
    func filteredBootstrap(_ level: String) async throws {
        try await filteredOutput(shell: false, level: level)
    }

    @Test(
        "logging filters shell diagnostics without losing captured bytes",
        .enabled(if: ProcessInfo.processInfo.environment["TMUX_WORKSPACE_TEST_PYTHON"] != nil),
        arguments: ["warning", "error"])
    func filteredShell(_ level: String) async throws {
        try await filteredOutput(shell: true, level: level)
    }

    private func filteredOutput(shell: Bool, level: String) async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let captured = ProcessOutput(gate: root.appendingPathComponent("unused-gate"))
            var environment = ProcessInfo.processInfo.environment
            environment["LIBTMUX_TMUX_BIN"] = server.tmuxExecutable
            environment["TMUX_WORKSPACE_PYTHON"] = environment["TMUX_WORKSPACE_TEST_PYTHON"]
            let context = CLIContext(
                directory: root, environment: environment,
                output: { await captured.record($0) },
                error: { try await captured.diagnostic($0) })
            var arguments: [String]
            if shell {
                let session = try await server.sessions()[0]
                arguments = [
                    "shell", session.name, "--code", "--no-startup", "-c",
                    "import sys; print('visible result'); print('quiet diagnostic', file=sys.stderr)",
                ]
            } else {
                let file = root.appendingPathComponent("quiet.json")
                try Data(
                    Value.object([
                        "session_name": .string("quiet"),
                        "before_script": .string(
                            "/bin/sh -c \"printf 'visible result'; printf 'quiet diagnostic' >&2\""),
                        "windows": .array([.object(["panes": .array([.null])])]),
                    ]).encoded().utf8
                ).write(to: file)
                arguments = ["load", file.path, "-d"]
            }
            let status = await WorkspaceCLI.run(
                arguments + ["-S", socket, "--json", "--log-level", level], context: context)
            #expect(status == 0)
            if level == "error" {
                #expect(await captured.diagnostics.isEmpty)
            } else {
                let stdout = await captured.stdout
                if shell {
                    #expect(stdout.hasSuffix("visible result\n"))
                } else {
                    #expect(stdout == "visible result")
                }
                #expect(await captured.stderr == "quiet diagnostic" + (shell ? "\n" : ""))
            }
            let records = await captured.records
            #expect(records.count == 1)
            let result = try #require(
                try JSONSerialization.jsonObject(with: Data(records.joined().utf8))
                    as? [String: Any])
            // `shell -c` keeps its own "success"/"error" status word; `load`
            // now uses the six-port envelope's "ok".
            #expect(result["status"] as? String == (shell ? "success" : "ok"))
            if shell {
                #expect((result["stdout"] as? String)?.hasSuffix("visible result\n") == true)
                #expect(result["stderr"] as? String == "quiet diagnostic\n")
            }
        }
    }

    @Test("captured output serializes every writer, not only the first two")
    func capturedOutputSerializesEveryWriter() async throws {
        let sink = SuspendedSink()
        let captured = CapturedOutput { text, stream in
            try await sink.append(text, stream: stream)
        }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try? await captured.append(Data("\(index)".utf8), stream: "stdout")
                }
            }
        }
        #expect(await sink.maximum == 1)
        #expect(await captured.stdout.sorted() == "01234567".sorted())
    }

    @Test("a writer cancelled before its turn throws instead of staying parked")
    func cancelledQueuedWriterThrows() async throws {
        let rendezvous = Rendezvous()
        let captured = CapturedOutput { _, _ in await rendezvous.arrive() }
        let holder = Task {
            try? await captured.append(Data("holder".utf8), stream: "stdout")
        }
        // The holder is inside the sink, so `busy` stays set until it is
        // released below — the queued writer below can never acquire its turn.
        await rendezvous.waitForArrival()

        let queued = Task {
            try await captured.append(Data("queued".utf8), stream: "stdout")
        }
        queued.cancel()
        await #expect(throws: CancellationError.self) {
            try await queued.value
        }

        await rendezvous.release()
        _ = await holder.value
    }

    @Test("child environments refuse names no environ entry can express")
    func invalidEnvironmentName() async throws {
        for name in ["A=B", "", "A\0B"] {
            var invalid = try context()
            invalid.environment[name] = "injected"
            await #expect(throws: CLIError.self) {
                try await ProcessCommands.run(
                    ["/bin/sh", "-c", #"printf '%s' "${A-}""#], context: invalid)
            }
        }
        let result = try await ProcessCommands.run(
            ["/bin/sh", "-c", #"printf '%s' "${A-}""#], context: try context())
        #expect(result.code == 0)
    }

    /// A child cannot start in a directory that is not there, and the suite
    /// root only exists once some case has made it.
    private func context() throws -> CLIContext {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return CLIContext(
            directory: directory,
            environment: ProcessInfo.processInfo.environment, output: { _ in }, error: { _ in })
    }
}

private actor ProcessReceipt {
    var pid: Int32?
    var writes = 0
    var ready: Bool { pid != nil && writes > 0 }
    private var prefix = ""
    func writing(_ text: String) {
        if pid == nil {
            prefix += text
            if let end = prefix.firstIndex(of: "\n") { pid = Int32(prefix[..<end]) }
        }
        writes += 1
    }
}

/// Lets a test hold a `CapturedOutput` sink open on demand instead of on a
/// timer, so a second writer is provably still queued when it is cancelled.
private actor Rendezvous {
    private var arrivedContinuation: CheckedContinuation<Void, Never>?
    private var didArrive = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    func arrive() async {
        didArrive = true
        arrivedContinuation?.resume()
        arrivedContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForArrival() async {
        guard !didArrive else { return }
        await withCheckedContinuation { arrivedContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SuspendedSink {
    var active = 0
    var maximum = 0
    var stdout = ""
    var stderr = ""

    func append(_ text: String, stream: String) async throws {
        active += 1
        maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(2))
        if stream == "stdout" { stdout += text } else { stderr += text }
    }
}

private actor ProcessOutput {
    let gate: URL
    var stdout = ""
    var stderr = ""
    var released = false
    var records: [String] = []
    var diagnostics: [String] = []

    init(gate: URL) { self.gate = gate }

    func record(_ text: String) { records.append(text) }

    func diagnostic(_ text: String) throws {
        diagnostics.append(text)
        guard
            let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let code = value["code"] as? String,
            ["bootstrap_stdout", "bootstrap_stderr", "shell_stdout", "shell_stderr"].contains(code),
            let message = value["message"] as? String
        else { return }
        try append(message, stream: code.hasSuffix("_stdout") ? "stdout" : "stderr")
    }

    func append(_ text: String, stream: String) throws {
        if stream == "stdout" { stdout += text } else { stderr += text }
        if !released && stdout.contains("first-data") {
            try Data("release".utf8).write(to: gate)
            released = true
        }
    }
}
