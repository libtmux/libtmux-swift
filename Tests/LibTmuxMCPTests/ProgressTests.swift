import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

/// Collects what a server wrote out of band.
private actor Emitted {
    private(set) var lines: [String] = []
    func record(_ line: String) { lines.append(line) }

    var notifications: [JSONValue] {
        lines.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            .filter { $0["method"]?.stringValue == "notifications/progress" }
    }
}

private actor ProgressGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let suspended = waiters
        waiters.removeAll()
        for waiter in suspended { waiter.resume() }
    }
}

private actor ProgressResult {
    private(set) var value: Int?

    func record(_ value: Int) {
        self.value = value
    }
}

private enum ProgressHorizonEvent: Sendable, Equatable {
    case terminal
    case watchdog
}

@Suite("progress", .timeLimit(.minutes(2)))
struct ProgressTests {
    @Test("a client that asks to be told is told, while the call is still running")
    func progressIsReportedDuringALongCall() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
            let emitted = Emitted()
            let handler = MCPRequestHandler(
                tools: TmuxTools(server: server, waitCeiling: .seconds(30))
            )
            _ = await handler.respond(
                to: #"""
                    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
                    "name":"wait_for_output","arguments":{"pane":"\#(paneRef)",
                    "patterns":["never-arrives"],"require_fresh":true,"timeout":6},
                    "_meta":{"progressToken":"tok"}}}
                    """#.replacingOccurrences(of: "\n", with: ""),
                emit: { await emitted.record($0) }
            )

            let notifications = await emitted.notifications
            #expect(!notifications.isEmpty, "a six-second wait reported nothing")
            for notification in notifications {
                let params = try #require(notification["params"])
                #expect(params["progressToken"]?.stringValue == "tok")
                #expect(params["total"]?.doubleValue == 6)
                #expect(params["message"]?.stringValue?.isEmpty == false)
            }
            // Monotonic, which the specification requires and a client uses to
            // decide a frame is not a duplicate.
            let values = notifications.compactMap { $0["params"]?["progress"]?.doubleValue }
            #expect(values == values.sorted())
        }
    }

    @Test("a token of zero is a token, not an absent one")
    func zeroIsAValidToken() async throws {
        // Measured against the Codex CLI, which numbers its tokens from zero.
        // Reading the field as falsy would silence exactly the first call of
        // every session.
        let token = ProgressReporter.token(
            in: .object(["_meta": .object(["progressToken": .number(0)])])
        )
        #expect(token == .number(0))
    }

    @Test("an oversized progress token emits no oversized protocol line")
    func oversizedProgressIsNotEmitted() async {
        let emitted = Emitted()
        let reporter = ProgressReporter(
            token: .string(String(repeating: "\\", count: 600_000)),
            emit: { await emitted.record($0) }
        )

        await reporter.report(1, of: 2, "running")
        #expect(await emitted.lines.isEmpty)
    }

    @Test("work can outlive the reporting horizon")
    func workOutlivesReportingHorizon() async {
        let releaseWork = ProgressGate()
        let completion = ProgressResult()
        let (events, eventWitness) = AsyncStream.makeStream(
            of: ProgressHorizonEvent.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let reporter = ProgressReporter(token: .string("tok")) { line in
            guard
                let notification = try? JSONDecoder().decode(
                    JSONValue.self,
                    from: Data(line.utf8)
                ),
                notification["params"]?["progress"]?.doubleValue == 0.02
            else { return }
            eventWitness.yield(.terminal)
        }
        let running = Task {
            let value = await reporter.whileRunning(
                upTo: .milliseconds(20),
                every: .milliseconds(10),
                describing: "waiting"
            ) {
                await releaseWork.wait()
                return 37
            }
            await completion.record(value)
            return value
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            eventWitness.yield(.watchdog)
        }

        var eventIterator = events.makeAsyncIterator()
        let first = await eventIterator.next()
        watchdog.cancel()
        await watchdog.value
        eventWitness.finish()

        #expect(first == .terminal)
        #expect(await completion.value == nil)
        await releaseWork.open()
        #expect(await running.value == 37)
    }

    @Test("completed work cancels its heartbeat")
    func completedWorkCancelsHeartbeat() async {
        let emitted = Emitted()
        let reporter = ProgressReporter(
            token: .string("tok"),
            emit: { await emitted.record($0) }
        )
        let (completions, completionWitness) = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let running = Task {
            let value = await reporter.whileRunning(
                upTo: .seconds(30),
                every: .seconds(30),
                describing: "waiting"
            ) {
                42
            }
            completionWitness.yield(value)
            completionWitness.finish()
            return value
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            completionWitness.yield(0)
        }

        var completionIterator = completions.makeAsyncIterator()
        let completed = await completionIterator.next()
        watchdog.cancel()
        completionWitness.finish()
        running.cancel()
        _ = await running.value

        #expect(completed == 42)
        #expect(await emitted.lines.isEmpty)
    }

    @Test("a client that did not ask is not sent anything")
    func silenceWithoutAToken() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
            let emitted = Emitted()
            let handler = MCPRequestHandler(
                tools: TmuxTools(server: server, waitCeiling: .seconds(30))
            )
            _ = await handler.respond(
                to: #"""
                    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
                    "name":"wait_for_output","arguments":{"pane":"\#(paneRef)",
                    "patterns":["never-arrives"],"require_fresh":true,"timeout":4}}}
                    """#.replacingOccurrences(of: "\n", with: ""),
                emit: { await emitted.record($0) }
            )
            // An unsolicited notification is a protocol error, not a courtesy.
            #expect(await emitted.lines.isEmpty)
        }
    }

    @Test("progress and the answer never interleave on the one stream")
    func progressSharesTheWriterWithTheAnswer() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
            let emitted = Emitted()
            let service = MCPService(
                handler: MCPRequestHandler(
                    tools: TmuxTools(server: server, waitCeiling: .seconds(30))
                )
            )
            let lines = AsyncStream<String> { continuation in
                continuation.yield(
                    #"""
                    {"jsonrpc":"2.0","id":"w","method":"tools/call","params":{
                    "name":"wait_for_output","arguments":{"pane":"\#(paneRef)",
                    "patterns":["never-arrives"],"require_fresh":true,"timeout":5},
                    "_meta":{"progressToken":7}}}
                    """#.replacingOccurrences(of: "\n", with: "")
                )
                continuation.finish()
            }
            await service.serve(lines) { await emitted.record($0) }

            let written = await emitted.lines
            // Every line is one whole JSON document: a notification written
            // into the middle of a response would desynchronise the stream for
            // good, and this is the only place that could happen.
            for line in written {
                #expect(!line.contains("\n"))
                #expect(
                    (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))) != nil,
                    "a line was not whole JSON: \(line.prefix(80))"
                )
            }
            let answers = written.filter {
                (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?["id"] != nil
            }
            #expect(answers.count == 1, "the request was answered exactly once")
            #expect(written.count > answers.count, "progress was reported alongside it")
        }
    }

    @Test("search reports the panes it has got through, not a timer")
    func searchReportsPanesSearched() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            _ = try await server.split(pane)
            let emitted = Emitted()
            let handler = MCPRequestHandler(tools: TmuxTools(server: server))
            _ = await handler.respond(
                to: #"""
                    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
                    "name":"search_panes","arguments":{"pattern":"nothing-matches-this"},
                    "_meta":{"progressToken":1}}}
                    """#.replacingOccurrences(of: "\n", with: ""),
                emit: { await emitted.record($0) }
            )
            let notifications = await emitted.notifications
            #expect(!notifications.isEmpty)
            // This one has a real denominator, so it reports work rather than
            // elapsed time.
            let totals = notifications.compactMap { $0["params"]?["total"]?.doubleValue }
            #expect(totals.allSatisfy { $0 >= 2 })
        }
    }
}
