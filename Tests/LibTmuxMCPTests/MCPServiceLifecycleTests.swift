import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

private enum WriterFailureEvent: Sendable, Equatable {
    case wrote(String)
    case serviceCompleted
    case watchdog
}

@Suite("MCP service lifecycle", .timeLimit(.minutes(1)))
struct MCPServiceLifecycleTests {
    @Test("writer failure ends service before input ends")
    func writerFailureEndsUnfinishedInput() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/writer-failure-unstarted"
        )
        let service = MCPService(
            handler: MCPRequestHandler(tools: TmuxTools(server: server))
        )
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let (events, eventWitness) = AsyncStream<WriterFailureEvent>.makeStream()
        let serving = Task {
            await service.serveUntilWriteFails(lines) { line in
                eventWitness.yield(.wrote(line))
                return false
            }
            eventWitness.yield(.serviceCompleted)
        }

        continuation.yield(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            eventWitness.yield(.watchdog)
        }

        var iterator = events.makeAsyncIterator()
        guard case let .wrote(line)? = await iterator.next() else {
            Issue.record("the service completed before invoking its writer")
            watchdog.cancel()
            serving.cancel()
            continuation.finish()
            eventWitness.finish()
            await serving.value
            await watchdog.value
            return
        }
        #expect(line.contains(#""id":1"#))
        #expect(await iterator.next() == .serviceCompleted)

        watchdog.cancel()
        serving.cancel()
        continuation.finish()
        eventWitness.finish()
        await serving.value
        await watchdog.value
    }

    @Test("cancelling the service cancels active request work")
    func serviceCancellationReachesRequests() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
            let output = LifecycleOutput()
            let service = MCPService(
                handler: MCPRequestHandler(
                    tools: TmuxTools(server: server, waitCeiling: .seconds(10))
                )
            )
            let (lines, continuation) = AsyncStream<String>.makeStream()
            let serving = Task {
                await service.serve(lines) { await output.write($0) }
            }

            continuation.yield(
                #"""
                {"jsonrpc":"2.0","id":"wait","method":"tools/call","params":{
                "name":"wait_for_output","arguments":{"pane":"\#(paneRef)",
                "patterns":["never-arrives"],"require_fresh":true,"timeout":4},
                "_meta":{"progressToken":"active"}}}
                """#.replacingOccurrences(of: "\n", with: "")
            )
            let becameActive = try await waitUntil(within: .seconds(3)) {
                await output.containsProgress
            }
            guard becameActive else {
                serving.cancel()
                continuation.finish()
                await serving.value
                Issue.record(
                    "the request never reported that it was active: \(await output.snapshot)"
                )
                return
            }

            let cancelledAt = ContinuousClock.now
            serving.cancel()
            await serving.value
            continuation.finish()

            #expect(ContinuousClock.now - cancelledAt < .seconds(1))
            #expect(await output.responses(withID: "wait").isEmpty)
        }
    }

    @Test("a blocked output write does not block later cancellation input")
    func blockedOutputDoesNotBlockCancellation() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
            let incarnation = try await server.incarnation()
            let serverRef = WireReferenceCodec.processLocal.reference(to: incarnation)
            let output = LifecycleOutput(blocked: true)
            let service = MCPService(
                handler: MCPRequestHandler(
                    tools: TmuxTools(
                        server: server,
                        tier: .destructive,
                        waitCeiling: .seconds(10)
                    )
                )
            )
            let (lines, continuation) = AsyncStream<String>.makeStream()
            let serving = Task {
                await service.serve(lines) { await output.write($0) }
            }

            continuation.yield(
                #"""
                {"jsonrpc":"2.0","id":"wait","method":"tools/call","params":{
                "name":"wait_for_output","arguments":{"pane":"\#(paneRef)",
                "patterns":["never-arrives"],"require_fresh":true,"timeout":4}}}
                """#.replacingOccurrences(of: "\n", with: "")
            )
            continuation.yield("{")

            let writerBlocked = try await waitUntil(within: .seconds(1)) {
                await output.hasWrite
            }
            continuation.yield(
                #"""
                {"jsonrpc":"2.0","method":"notifications/cancelled",
                "params":{"requestId":"wait"}}
                """#.replacingOccurrences(of: "\n", with: "")
            )
            continuation.yield(
                #"""
                {"jsonrpc":"2.0","id":"after","method":"tools/call","params":{
                "name":"run_command","arguments":{"server_ref":"\#(serverRef)",
                "command":"new-session","arguments":["-d","-s","after-cancel"],
                "confirm_unsafe":true}}}
                """#.replacingOccurrences(of: "\n", with: "")
            )

            let inputCrossedBlockedWrite = try await waitUntil(within: .seconds(1)) {
                try await server.hasSession("after-cancel")
            }

            await output.release()
            continuation.finish()
            await serving.value

            #expect(writerBlocked)
            #expect(inputCrossedBlockedWrite)
            #expect(await output.responses(withID: "wait").isEmpty)
        }
    }
}

private actor LifecycleOutput {
    private var lines: [String] = []
    private var blocked: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(blocked: Bool = false) {
        self.blocked = blocked
    }

    func write(_ line: String) async {
        lines.append(line)
        guard blocked else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    var hasWrite: Bool { !lines.isEmpty }

    var snapshot: [String] { lines }

    var containsProgress: Bool {
        lines.contains {
            (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?["method"]
                == .string("notifications/progress")
        }
    }

    func responses(withID id: String) -> [String] {
        lines.filter { $0.contains(#""id":"\#(id)""#) }
    }

    func release() {
        blocked = false
        let suspended = waiters
        waiters.removeAll()
        for waiter in suspended { waiter.resume() }
    }
}
