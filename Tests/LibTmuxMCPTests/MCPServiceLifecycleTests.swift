import LibTmux
import Testing

@testable import LibTmuxMCP

private enum ServiceEvent: Sendable, Equatable {
    case wrote
    case completed
    case watchdog
}

@Suite("MCP service lifecycle", .timeLimit(.minutes(5)))
struct MCPServiceLifecycleTests {
    @Test("writer failure ends service before input closes")
    func writerFailureEndsUnfinishedInput() async throws {
        let server = try Server(socketPath: "/tmp/libtmux-swift-test/writer-failure-unstarted")
        let tools = TmuxTools(
            server: server,
            authority: ToolAuthority(toolsets: [.inspect]),
            caller: nil
        )
        let service = MCPService(handler: MCPRequestHandler(tools: tools))
        let (lines, input) = AsyncStream<String>.makeStream()
        let (events, witness) = AsyncStream<ServiceEvent>.makeStream()
        let serving = Task {
            await service.serveUntilWriteFails(lines) { _ in
                witness.yield(.wrote)
                return false
            }
            witness.yield(.completed)
        }
        input.yield(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            witness.yield(.watchdog)
        }

        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .wrote)
        #expect(await iterator.next() == .completed)

        watchdog.cancel()
        serving.cancel()
        input.finish()
        witness.finish()
        await serving.value
        await watchdog.value
    }
}
