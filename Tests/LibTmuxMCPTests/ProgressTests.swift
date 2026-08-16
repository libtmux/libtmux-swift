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

@Suite("progress", .timeLimit(.minutes(2)))
struct ProgressTests {
    @Test("a client that asks to be told is told, while the call is still running")
    func progressIsReportedDuringALongCall() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let emitted = Emitted()
            let handler = MCPRequestHandler(
                tools: TmuxTools(server: server, waitCeiling: .seconds(30))
            )
            _ = await handler.respond(
                to: #"""
                    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
                    "name":"wait_for_output","arguments":{"pane":"\#(pane.id)",
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

    @Test("a client that did not ask is not sent anything")
    func silenceWithoutAToken() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let emitted = Emitted()
            let handler = MCPRequestHandler(
                tools: TmuxTools(server: server, waitCeiling: .seconds(30))
            )
            _ = await handler.respond(
                to: #"""
                    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
                    "name":"wait_for_output","arguments":{"pane":"\#(pane.id)",
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
                    "name":"wait_for_output","arguments":{"pane":"\#(pane.id)",
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
