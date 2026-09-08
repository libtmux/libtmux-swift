import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("capability regressions", .timeLimit(.minutes(1)))
struct CapabilityRegressionTests {
    private func tools(_ server: Server) -> TmuxTools {
        TmuxTools(
            server: server,
            authority: ToolAuthority(toolsets: [.inspect, .manage, .execute, .teardown]),
            caller: nil
        )
    }

    @Test("effective aggregate disclosures are the exact nested union")
    func effectiveAggregateDisclosuresAreExact() throws {
        let source = try #require(TmuxTools.byName["call_read_tools_batch"])
        let empty = source.restrictingNestedAuthority(to: [])

        #expect(empty.tmuxEffects == [.observe])
        #expect(empty.outputClasses.isEmpty)
        #expect(!empty.mayExposeSecrets)
        #expect(!empty.mayReturnUntrustedContent)
    }

    @Test("wire capability rows expose one canonical literalization map")
    func capabilityRowsExposeCanonicalLiteralization() throws {
        for definition in TmuxTools.definitions {
            #expect(definition.capabilityRow["tmuxFormatControls"] == nil)
            #expect(definition.capabilityRow["inputSinks"] == nil)
        }

        let variables = try #require(TmuxTools.byName["get_tmux_variables"])
        #expect(
            variables.capabilityRow["inputLiteralization"]?["names"]?.stringValue
                == "validated-variable-name"
        )
    }

    @Test("capability resource reports the shared boundary and connection shape")
    func capabilityResourceUsesSharedReportShape() throws {
        let socketPath = "/tmp/libtmux-swift-test/capability-report-unstarted"
        let server = try Server(socketPath: socketPath)
        let exposed = TmuxTools(
            server: server,
            authority: ToolAuthority(toolsets: []),
            caller: nil,
            provenance: ServerProvenance(
                selector: "path:\(socketPath)",
                selectionProvenance: "operator-current",
                serverState: "absent",
                configurationProvenance: "user-configured"
            )
        )
        let resource = try CapabilityResources(tools: exposed).read(CapabilityResources.uri)
        let text = try #require(resource["text"]?.stringValue)
        let report = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))

        #expect(
            report["boundary"]
                == .object([
                    "oneSocketPerProcess": .bool(true),
                    "perCallSocketSelection": .bool(false),
                    "hostCommandExecution": .bool(false),
                    "dynamicResources": .bool(false),
                ]))
        #expect(report["connection"]?["socketSelector"]?.stringValue == "path:\(socketPath)")
        #expect(
            report["connection"]?["socketProvenance"]?.stringValue == "operator-current"
        )
        #expect(report["connection"]?["resolvedSocketPath"]?.stringValue == socketPath)
        #expect(report["connection"]?["serverState"]?.stringValue == "absent")
        #expect(
            report["connection"]?["configurationProvenance"]?.stringValue
                == "user-configured"
        )
        let attachCommand = try #require(
            report["connection"]?["attachCommand"]?.stringValue
        )
        #expect(attachCommand.contains(" -N -S '\(socketPath)' attach"))
    }

    @Test("read batch rolls back the row that crosses the wire budget")
    func readBatchRollsBackCrossingRow() throws {
        var batch = ReadBatchAccumulator(total: 2)
        let acceptedFirst = batch.append(
            tool: "list_sessions",
            outcome: ToolOutcome(
                structured: .object([
                    "sessions": .array([
                        .object(["name": .string(String(repeating: "a", count: 300_000))])
                    ])
                ]))
        )
        let acceptedSecond = batch.append(
            tool: "list_sessions",
            outcome: ToolOutcome(
                structured: .object([
                    "sessions": .array([
                        .object(["name": .string(String(repeating: "b", count: 200_000))])
                    ])
                ]))
        )
        #expect(acceptedFirst)
        #expect(acceptedSecond)

        let rows = try #require(batch.finish()["results"]?.arrayValue)
        #expect(rows[0]["resultTruncated"]?.boolValue == false)
        #expect(rows[1]["resultTruncated"]?.boolValue == true)
    }

    @Test("read batch limits the complete JSON-RPC response, including its id")
    func readBatchLimitsCompleteResponse() throws {
        var batch = ReadBatchAccumulator(total: 1)
        let accepted = batch.append(
            tool: "list_sessions",
            outcome: ToolOutcome(
                structured: .object([
                    "sessions": .array([
                        .object(["name": .string(String(repeating: "x", count: 430_000))])
                    ])
                ]))
        )
        #expect(accepted)
        #expect(batch.finish()["truncated"]?.boolValue == false)

        let socketPath = "/tmp/libtmux-swift-test/batch-full-wire-unstarted"
        let handler = MCPRequestHandler(
            tools: TmuxTools(
                server: try Server(socketPath: socketPath),
                authority: ToolAuthority(toolsets: [.inspect]),
                caller: nil
            )
        )
        let response = try #require(
            handler.toolResponse(
                id: .string(String(repeating: "request-id", count: 16_000)),
                outcome: batch.finishOutcome()
            )
        )
        #expect(response.utf8.count <= MCPRequestHandler.maximumResponseBytes)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
        #expect(decoded["result"]?["isError"]?.boolValue == false)
        let structured = try #require(decoded["result"]?["structuredContent"])
        #expect(structured["truncated"]?.boolValue == true)
        #expect(structured["truncatedBytes"]?.intValue ?? 0 > 0)
        #expect(
            structured["results"]?.arrayValue?.first?["resultTruncated"]?.boolValue == true
        )
    }

    @Test("the response limit includes its newline delimiter")
    func responseLimitIncludesNewline() throws {
        let handler = MCPRequestHandler(
            tools: TmuxTools(
                server: try Server(
                    socketPath: "/tmp/libtmux-swift-test/response-line-unstarted"
                ),
                authority: ToolAuthority(toolsets: []),
                caller: nil
            )
        )
        let empty = try #require(
            handler.toolResponse(
                id: .integer(1),
                outcome: ToolOutcome(
                    structured: .object(["padding": .string("")]),
                    text: "bounded response"
                )
            )
        )
        let padding = String(
            repeating: "x",
            count: MCPRequestHandler.maximumResponseBytes - empty.utf8.count
        )
        let response = try #require(
            handler.toolResponse(
                id: .integer(1),
                outcome: ToolOutcome(
                    structured: .object(["padding": .string(padding)]),
                    text: "bounded response"
                )
            )
        )

        #expect(response.utf8.count + 1 <= MCPRequestHandler.maximumResponseBytes)
    }

    @Test("wait resumes from its cursor, honors output bounds, and stops on failure text")
    func waitResumesFromCursorAndHonorsBounds() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)

            let started = try await surface.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["paneId": .string(pane.id.rawValue)])
                )
            )
            let cursor = try #require(started.structured["cursor"]?.stringValue)
            try await server.run(
                "for i in $(seq 1 35); do printf 'cursor-line-%s\\n' \"$i\"; done; "
                    + "printf 'fatal-cursor-marker\\n'",
                in: pane
            )
            #expect(
                try await waitUntil {
                    try await server.capture(pane).contains { $0.contains("fatal-cursor-marker") }
                }
            )

            let waited = try await surface.call(
                ToolCall(
                    name: "wait_for_text",
                    arguments: .object([
                        "cursor": .string(cursor),
                        "maxLines": .integer(30),
                        "paneId": .string(pane.id.rawValue),
                        "patterns": .array([.string("never-matches")]),
                        "stop": .array([.string("fatal-cursor-marker")]),
                        "timeoutMs": .integer(1_000),
                    ])
                )
            )

            #expect(waited.structured["outcome"]?.stringValue == "stopped")
            #expect(waited.structured["matched"]?.stringValue == "fatal-cursor-marker")
            #expect(waited.structured["tail"]?.arrayValue?.count == 30)
            let returnedCursor = waited.structured["cursor"]?.stringValue
            #expect(returnedCursor != nil)
            #expect(returnedCursor?.isEmpty == false)
        }
    }
}
