import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

@Suite("capability manifest", .timeLimit(.minutes(1)))
struct CapabilityManifestTests {
    private let toolsByToolset: [(String, [String])] = [
        (
            "inspect",
            [
                "call_read_tools_batch", "capture_pane", "capture_since",
                "find_pane_by_position", "get_pane_info", "get_server_info",
                "get_session_info", "get_tmux_variables", "get_window_info", "list_panes",
                "list_sessions", "list_windows", "search_panes", "show_environment",
                "show_hooks", "show_option", "snapshot_pane", "wait_for_text",
            ]
        ),
        (
            "manage",
            [
                "move_window", "rename_session", "rename_window", "resize_pane",
                "resize_window", "select_layout", "select_pane", "select_window",
                "set_history_limit", "set_mouse_enabled", "set_pane_title", "signal_channel",
                "swap_pane", "wait_for_channel",
            ]
        ),
        (
            "execute",
            [
                "create_session", "create_window", "paste_text", "respawn_pane",
                "run_shell_command", "send_keys", "send_keys_batch",
                "set_synchronize_panes", "split_window",
            ]
        ),
        (
            "teardown",
            ["clear_pane_scrollback", "kill_pane", "kill_session", "kill_window"]
        ),
    ]

    @Test("one registry governs every effective surface and capability claim")
    func oneRegistryGovernsEverySurface() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/capability-manifest-unstarted"
        )
        let allExpected = Set(toolsByToolset.flatMap(\.1))
        #expect(allExpected.count == 45)
        #expect(toolsByToolset.map { $0.1.count } == [18, 14, 9, 4])
        #expect(ToolOperation.allCases.count == 45)
        #expect(Set(TmuxTools.definitions.map(\.name)) == allExpected)
        #expect(TmuxTools.definitions.map(\.name) == toolsByToolset.flatMap(\.1))
        let outputSchemas = try TmuxTools.definitions.map { definition in
            try #require(definition.outputSchema)
        }
        #expect(
            outputSchemas.allSatisfy {
                $0["type"]?.stringValue == "object"
                    && $0["additionalProperties"]?.boolValue == false
            }
        )
        #expect(Set(outputSchemas).count >= 20)
        #expect(
            TmuxTools.definitions.filter(\.amplifiesFutureInput).map(\.name)
                == ["set_synchronize_panes"]
        )
        #expect(
            TmuxTools.definitions.first { $0.name == "set_synchronize_panes" }?.description
                .contains("subsequent input to one pane is copied to every pane") == true
        )
        for definition in TmuxTools.definitions {
            #expect(!definition.tmuxEffects.isEmpty)
            #expect(!definition.outputClasses.isEmpty)
            #expect(definition.mayExposeSecrets)
            #expect(definition.mayReturnUntrustedContent)
            #expect(definition.explicitAnnotations == .conservative)
            #expect(Set(definition.inputSinks.keys) == Set(definition.arguments.map(\.name)))
            #expect(definition.inputSinks.values.allSatisfy { !$0.isEmpty })
            for (name, sinks) in definition.inputSinks where sinks.contains(.tmuxFormat) {
                #expect(
                    definition.arguments.first { $0.name == name }?.tmuxFormatControl != nil
                )
            }
        }
        let declaredSinks = Set(
            TmuxTools.definitions.flatMap(\.inputSinks.values).flatMap { $0 }.map(\.rawValue)
        )
        #expect(
            declaredSinks.isSubset(
                of: [
                    "none", "tmux-lookup", "tmux-state", "pane-input", "shell-command",
                    "process-argv", "regex", "tmux-format", "nested-tool",
                ]
            )
        )
        #expect(InputSink(rawValue: "host-command") == nil)
        let controlledOpeners: [(Set<String>, String)] = [
            (
                [
                    "find_pane_by_position", "get_pane_info", "get_server_info",
                    "get_session_info", "get_window_info", "list_panes", "list_sessions",
                    "list_windows",
                ],
                "Inspect tmux metadata; accepts no client-supplied executable input."
            ),
            (
                [
                    "call_read_tools_batch", "capture_pane", "capture_since", "search_panes",
                    "snapshot_pane", "wait_for_text",
                ],
                "Read pane output; accepts no client-supplied executable input. Returned content may be sensitive or untrusted."
            ),
            (
                ["show_environment"],
                "Read the tmux environment; accepts no client-supplied executable input. Returned values may contain secrets."
            ),
            (
                ["get_tmux_variables", "show_hooks", "show_option"],
                "Read configured tmux commands; accepts no client-supplied executable input. Returned values may contain executable configuration."
            ),
            (
                Set(toolsByToolset[1].1).union(["set_synchronize_panes"]),
                "Change tmux state; no client-supplied executable input."
            ),
            (
                ["create_session", "create_window", "respawn_pane", "split_window"],
                "Start a pane's configured process; accepts no command payload."
            ),
            (
                ["paste_text", "send_keys", "send_keys_batch"],
                "Send input to a pane's program; a shell that receives it runs it with your user's permissions."
            ),
            (
                ["run_shell_command"],
                "Run a shell command in a pane with your user's permissions."
            ),
            (
                Set(toolsByToolset[3].1),
                "Delete tmux state; accepts no command payload."
            ),
        ]
        #expect(controlledOpeners.reduce(0) { $0 + $1.0.count } == 45)
        for (names, opener) in controlledOpeners {
            for name in names {
                let definition = try #require(TmuxTools.definitions.first { $0.name == name })
                #expect(definition.description.hasPrefix(opener + " "), "\(name) opener")
            }
        }

        let empty = ServerConfiguration(environment: ["LIBTMUX_TOOLSETS": ""])
        #expect(empty.errors.isEmpty)
        #expect(empty.authority.toolsets.isEmpty)
        #expect(
            ServerConfiguration(environment: ["LIBTMUX_TMUX_CONFIG": "/tmp/tmux.conf"])
                .errors.isEmpty
        )
        for invalid in ["", "relative.conf"] {
            #expect(
                ServerConfiguration(environment: ["LIBTMUX_TMUX_CONFIG": invalid])
                    .errors.contains { $0.contains("absolute path") }
            )
        }
        for environment in [
            ["LIBTMUX_TOOLSETS": "inspect,"],
            ["LIBTMUX_TOOLSETS": "unknown"],
            ["LIBTMUX_TOOLS": "unknown"],
            ["LIBTMUX_EXCLUDE_TOOLS": "kill_pane,,kill_window"],
            ["LIBTMUX_SAFETY": "readonly"],
            ["LIBTMUX_MCP_TOOLS": "list_sessions"],
        ] {
            #expect(!ServerConfiguration(environment: environment).errors.isEmpty)
        }
        let retiredAllowlist = ServerConfiguration(
            environment: ["LIBTMUX_MCP_TOOLS": "list_sessions"]
        )
        #expect(
            retiredAllowlist.errors.contains {
                $0.contains("LIBTMUX_TOOLSETS=") && $0.contains("LIBTMUX_TOOLS")
            }
        )

        for mask in 0..<(1 << toolsByToolset.count) {
            let selected = toolsByToolset.enumerated().compactMap { index, entry in
                mask & (1 << index) == 0 ? nil : entry.0
            }
            let expected = Set(
                toolsByToolset.enumerated().flatMap { index, entry in
                    mask & (1 << index) == 0 ? [] : entry.1
                }
            )
            let configuration = ServerConfiguration(
                environment: ["LIBTMUX_TOOLSETS": selected.joined(separator: ",")]
            )
            let tools = TmuxTools(
                server: server,
                authority: configuration.authority,
                caller: nil
            )
            #expect(Set(tools.visibleDefinitions.map(\.name)) == expected, "mask \(mask)")
        }

        let selected = ServerConfiguration(
            environment: [
                "LIBTMUX_TOOLSETS": "inspect",
                "LIBTMUX_TOOLS": "run_shell_command,kill_pane",
                "LIBTMUX_EXCLUDE_TOOLS": "list_sessions,kill_pane",
            ]
        )
        let tools = TmuxTools(server: server, authority: selected.authority, caller: nil)
        let expectedSelected =
            Set(toolsByToolset[0].1).subtracting(["list_sessions"])
            .union(["run_shell_command"])
        #expect(Set(tools.visibleDefinitions.map(\.name)) == expectedSelected)
        let batch = try #require(
            tools.visibleDefinitions.first { $0.name == "call_read_tools_batch" }
        )
        #expect(batch.description.contains("inner tools receive no separate approval"))
        #expect(batch.description.contains("marked resultTruncated"))
        #expect(batch.description.contains("1,000,000-byte wire cap"))
        #expect(
            batch.nestedAuthority
                == Set(toolsByToolset[0].1).subtracting([
                    "call_read_tools_batch", "list_sessions", "wait_for_text",
                ])
        )
        #expect(nestedToolNames(in: batch) == batch.nestedAuthority)

        let handler = MCPRequestHandler(tools: tools)
        let listed = try await result(
            handler,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        )
        let listedTools = try #require(listed["tools"]?.arrayValue)
        #expect(Set(listedTools.compactMap { $0["name"]?.stringValue }) == expectedSelected)

        let resources = try await result(
            handler,
            #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#
        )
        #expect(
            resources["resources"]?.arrayValue?.compactMap { $0["uri"]?.stringValue }
                == ["tmux://capabilities"]
        )
        let templates = try await result(
            handler,
            #"{"jsonrpc":"2.0","id":3,"method":"resources/templates/list"}"#
        )
        #expect(templates["resourceTemplates"]?.arrayValue == [])

        let capabilities = try await result(
            handler,
            #"{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"tmux://capabilities"}}"#
        )
        let text = try #require(
            capabilities["contents"]?.arrayValue?.first?["text"]?.stringValue
        )
        let report = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(
            Set(report["effectiveTools"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                == expectedSelected
        )
        #expect(
            Set(report["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
                == expectedSelected
        )
        #expect(report["hostCommandTools"]?.intValue == 0)
        #expect(report["frozen"]?.boolValue == true)
        #expect(
            report["toolFilteringBoundary"]?.stringValue == "interface-shaping-not-authorization")
        #expect(report["executionAuthority"]?.stringValue == "tmux-user")
        #expect(report["operatingSystemBoundary"]?.stringValue == "none")
        #expect(report["boundary"]?["oneSocketPerProcess"]?.boolValue == true)
        #expect(report["boundary"]?["perCallSocketSelection"]?.boolValue == false)
        #expect(report["boundary"]?["hostCommandExecution"]?.boolValue == false)
        #expect(report["boundary"]?["dynamicResources"]?.boolValue == false)
        #expect(
            report["connection"]?["socketSelector"] == report["socket"]?["selector"]
        )
        #expect(
            report["connection"]?["socketProvenance"]
                == report["socket"]?["selectionProvenance"]
        )
        #expect(
            report["connection"]?["configurationProvenance"]
                == report["socket"]?["configurationProvenance"]
        )
        #expect(report["socket"]?["namespaceBoundary"]?.stringValue == "tmux-objects-only")
        #expect(report["toolCount"]?.intValue == expectedSelected.count)
        #expect(
            Set(report["socket"]?.objectValue.map { Array($0.keys) } ?? []) == [
                "selector", "selectionProvenance", "serverState", "configurationProvenance",
                "namespaceBoundary",
            ])
        for listedTool in listedTools {
            let name = try #require(listedTool["name"]?.stringValue)
            let row = try #require(
                report["tools"]?.arrayValue?.first { $0["name"]?.stringValue == name }
            )
            #expect(
                listedTool["_meta"]?["com.git-pull.libtmux-mcp/capability"] == row,
                "\(name) capability metadata"
            )
            #expect(
                Set(row["annotations"]?.objectValue.map { Array($0.keys) } ?? []) == [
                    "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint",
                ])
            let formatControlledInputs = Set(
                TmuxTools.byName[name]?.arguments.compactMap { argument in
                    argument.tmuxFormatControl == nil ? nil : argument.name
                } ?? []
            )
            #expect(
                Set(row["inputLiteralization"]?.objectValue.map { Array($0.keys) } ?? [])
                    == formatControlledInputs
            )
            let tmuxFormatInputs = Set(
                TmuxTools.byName[name]?.inputSinks.compactMap { input, sinks in
                    sinks.contains(.tmuxFormat) ? input : nil
                } ?? []
            )
            #expect(formatControlledInputs == tmuxFormatInputs)
            #expect(row["tmuxFormatControls"] == nil)
        }

        let variables = try #require(TmuxTools.byName["get_tmux_variables"])
        #expect(variables.inputSinks["names"] == [.tmuxLookup, .tmuxFormat])
        #expect(
            variables.capabilityRow["inputLiteralization"]?["names"]?.stringValue
                == "validated-variable-name"
        )

        let full = TmuxTools(
            server: server,
            authority: ServerConfiguration(
                environment: ["LIBTMUX_TOOLSETS": "inspect,manage,execute,teardown"]
            ).authority,
            caller: nil
        )
        for name in ["create_session", "create_window", "split_window", "respawn_pane"] {
            let definition = try #require(full.visibleDefinitions.first { $0.name == name })
            let properties = Set(
                definition.inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? []
            )
            #expect(!properties.contains("command"), "\(name) accepts command")
            #expect(!properties.contains("environment"), "\(name) accepts environment")
        }

        let readBatch = try #require(
            full.visibleDefinitions.first { $0.name == "call_read_tools_batch" }
        )
        #expect(
            readBatch.nestedAuthority
                == Set(toolsByToolset[0].1).subtracting([
                    "call_read_tools_batch", "wait_for_text",
                ])
        )
        #expect(
            readBatch.outputClasses
                == [
                    .tmuxMetadata, .terminalContent, .processEnvironment, .configuredCommand,
                ]
        )
        #expect(readBatch.tmuxEffects == [.observe])
        #expect(readBatch.inputSinks["operations"] == [.nestedTool])
        let sinkValues = { (tool: String, input: String) in
            Set(
                full.visibleDefinitions.first { $0.name == tool }?
                    .inputSinks[input]?.map(\.rawValue) ?? []
            )
        }
        #expect(sinkValues("call_read_tools_batch", "onError") == ["none"])
        #expect(
            sinkValues("capture_pane", "paneId") == ["tmux-lookup"]
        )
        #expect(
            sinkValues("capture_pane", "maxLines") == ["none"]
        )
        #expect(
            sinkValues("rename_session", "name") == ["tmux-state", "tmux-format"]
        )
        #expect(
            sinkValues("run_shell_command", "command") == ["pane-input", "shell-command"]
        )
        #expect(
            full.visibleDefinitions.first { $0.name == "capture_since" }?.tmuxEffects
                == [.observe]
        )
        #expect(readBatch.tmuxEffects == [.observe])
        #expect(
            sinkValues("wait_for_text", "patterns") == ["regex"]
        )

        let fullResource = try CapabilityResources(tools: full).read(CapabilityResources.uri)
        let fullText = try #require(fullResource["text"]?.stringValue)
        let fullReport = try JSONDecoder().decode(JSONValue.self, from: Data(fullText.utf8))
        let synchronize = try #require(
            fullReport["tools"]?.arrayValue?.first {
                $0["name"]?.stringValue == "set_synchronize_panes"
            }
        )
        #expect(synchronize["amplifiesFutureInput"]?.boolValue == true)
        #expect(synchronize["amplifies_future_input"] == nil)

        let aggregateOnly = TmuxTools(
            server: server,
            authority: ServerConfiguration(
                environment: [
                    "LIBTMUX_TOOLSETS": "", "LIBTMUX_TOOLS": "call_read_tools_batch",
                ]
            ).authority,
            caller: nil
        )
        #expect(aggregateOnly.visibleDefinitions.map(\.name) == ["call_read_tools_batch"])
        #expect(!aggregateOnly.exposes("get_server_info"))
        let nestedAttempt = try await aggregateOnly.call(
            ToolCall(
                name: "call_read_tools_batch",
                arguments: .object([
                    "operations": .array([
                        .object(["tool": .string("get_server_info")])
                    ])
                ])
            )
        )
        #expect(!nestedAttempt.text.contains("not enabled"))
        let aggregateBatch = try #require(aggregateOnly.visibleDefinitions.first)
        #expect(nestedToolNames(in: aggregateBatch) == aggregateBatch.nestedAuthority)

        let zeroNestedAuthority = TmuxTools(
            server: server,
            authority: ServerConfiguration(
                environment: [
                    "LIBTMUX_TOOLSETS": "",
                    "LIBTMUX_TOOLS": "call_read_tools_batch",
                    "LIBTMUX_EXCLUDE_TOOLS": aggregateBatch.nestedAuthority.sorted()
                        .joined(separator: ","),
                ]
            ).authority,
            caller: nil
        )
        let disabledBatch = try #require(zeroNestedAuthority.visibleDefinitions.first)
        #expect(disabledBatch.nestedAuthority.isEmpty)
        #expect(disabledBatch.tmuxEffects == [.observe])
        #expect(disabledBatch.outputClasses.isEmpty)
        #expect(
            disabledBatch.inputSchema["properties"]?["operations"]?["items"]?["not"]
                == .object([:])
        )
        let readBatchOperations = nestedOperationSchemas(in: readBatch)
        #expect(
            readBatchOperations.allSatisfy {
                Set($0["properties"]?.objectValue?.keys ?? [:].keys) == ["arguments", "tool"]
                    && $0["required"]?.arrayValue?.compactMap(\.stringValue) == ["tool"]
            }
        )
        #expect(nestedToolNames(in: readBatch) == readBatch.nestedAuthority)
        for operation in readBatchOperations {
            let name = try #require(operation["properties"]?["tool"]?["const"]?.stringValue)
            #expect(
                operation["properties"]?["arguments"] == TmuxTools.byName[name]?.inputSchema
            )
        }
        await #expect(throws: ToolError.self) {
            _ = try await aggregateOnly.call(
                ToolCall(
                    name: "call_read_tools_batch",
                    arguments: .object([
                        "operations": .array([
                            .object([
                                "tool": .string("get_server_info"),
                                "undeclared": .bool(true),
                            ])
                        ])
                    ])
                )
            )
        }

        let sendBatch = try #require(
            full.visibleDefinitions.first { $0.name == "send_keys_batch" }
        )
        #expect(sendBatch.nestedAuthority.isEmpty)
        #expect(
            full.visibleDefinitions.first { $0.name == "snapshot_pane" }?.nestedAuthority.isEmpty
                == true
        )
        let sendBatchItem = try #require(
            sendBatch.inputSchema["properties"]?["operations"]?["items"]
        )
        #expect(
            Set(sendBatchItem["properties"]?.objectValue?.keys ?? [:].keys)
                == ["enter", "force", "keys", "literal", "paneId"]
        )
        #expect(
            Set(sendBatchItem["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                == ["keys", "paneId"]
        )

        let defaultConfiguration = ServerConfiguration(environment: [:])
        #expect(defaultConfiguration.isDefaultDedicatedMinimal)
        #expect(defaultConfiguration.socketName == "libtmux-mcp")
        #expect(defaultConfiguration.socketPath == nil)
        #expect(defaultConfiguration.tmuxConfigurationFile?.hasSuffix("/minimal.conf") == true)
        #expect(
            defaultConfiguration.tmuxConfigurationFile.map(FileManager.default.fileExists) == true
        )
        #expect(!defaultConfiguration.authority.toolsets.contains(.teardown))
        #expect(defaultConfiguration.authority.resolve(TmuxTools.definitions).count == 41)
        #expect(TmuxTools(server: server).visibleDefinitions.count == 18)

        let instructions = Instructions.text(
            authority: ToolAuthority(toolsets: [.inspect]),
            waitCeiling: .seconds(120),
            caller: nil
        )
        #expect(instructions.contains("capture_pane start/end"))
        #expect(instructions.contains("search_panes"))
        #expect(instructions.contains("one MCP response, not one atomic read"))
        #expect(instructions.contains("opaque cursor"))
        #expect(instructions.contains("Pane modes are human-owned"))

        let named = ServerConfiguration(environment: ["LIBTMUX_SOCKET": "literal-name"])
        #expect(named.errors.isEmpty)
        #expect(!named.isDefaultDedicatedMinimal)
        #expect(named.socketName == "literal-name")
        #expect(named.socketPath == nil)
        #expect(named.tmuxConfigurationFile == nil)
        let path = ServerConfiguration(environment: ["LIBTMUX_SOCKET_PATH": "/tmp/mcp.sock"])
        #expect(path.errors.isEmpty)
        #expect(path.socketName == nil)
        #expect(path.socketPath == "/tmp/mcp.sock")
        let configured = ServerConfiguration(
            environment: ["LIBTMUX_TMUX_CONFIG": "/tmp/tmux.conf"]
        )
        #expect(configured.errors.isEmpty)
        #expect(configured.tmuxConfigurationFile == "/tmp/tmux.conf")
        for environment in [
            ["LIBTMUX_SOCKET": "name", "LIBTMUX_SOCKET_PATH": "/tmp/mcp.sock"],
            ["LIBTMUX_SOCKET": ""],
            ["LIBTMUX_SOCKET_PATH": "relative.sock"],
            ["LIBTMUX_TMUX_CONF": "/tmp/legacy.conf"],
        ] {
            #expect(!ServerConfiguration(environment: environment).errors.isEmpty)
        }
    }

    @Test("registered handlers consume the manifest's schema keys")
    func handlersConsumeManifestSchemaKeys() async throws {
        let definition = try #require(TmuxTools.byName["create_session"])
        let arguments = try Arguments(
            ToolCall(
                name: "create_session",
                arguments: .object(["name": .string("x"), "startDirectory": .string("/tmp")])
            ),
            for: definition
        )
        #expect(try arguments.optionalString("startDirectory") == "/tmp")
        #expect(try arguments.optionalString("start_directory") == nil)

        try await withTmuxServer { server in
            let tools = TmuxTools(
                server: server,
                authority: ToolAuthority(toolsets: [.execute]),
                caller: nil
            )
            _ = try await tools.call(
                ToolCall(
                    name: "create_session",
                    arguments: .object([
                        "name": .string("manifest-handler"),
                        "startDirectory": .string("/tmp"),
                        "windowName": .string("manifest-window"),
                    ])
                )
            )

            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first { $0.name == "manifest-handler" })
            let link = try #require(snapshot.windowLinks.first { $0.sessionID == session.id })
            let window = try #require(snapshot.windows.first { $0.id == link.windowID })
            let pane = try #require(snapshot.panes.first { $0.windowID == window.id })
            #expect(window.name == "manifest-window")
            #expect(pane.currentPath == "/tmp")
        }
    }

    @Test("read batch preserves bounded envelopes and fits the protocol wire cap")
    func readBatchPreservesBoundedEnvelopesWithinWireCap() async throws {
        var batch = ReadBatchAccumulator(total: 2)
        let first = ToolOutcome(
            structured: .object([
                "sessions": .array([
                    .object(["name": .string(String(repeating: "x", count: 350_000))])
                ])
            ])
        )

        let acceptedFirst = batch.append(tool: "list_sessions", outcome: first)
        let acceptedOversized = batch.append(
            tool: "list_sessions",
            outcome: ToolOutcome(
                structured: .object([
                    "sessions": .array([
                        .object(["name": .string(String(repeating: "x", count: 700_000))])
                    ])
                ])
            )
        )
        #expect(acceptedFirst)
        #expect(acceptedOversized)

        let outcome = batch.finishOutcome()
        let result = outcome.structured
        #expect(result["truncated"]?.boolValue == true)
        #expect(result["truncatedBytes"]?.intValue ?? 0 > 0)
        #expect(result["onError"]?.stringValue == "stop")
        #expect(result["succeeded"]?.intValue == 2)
        #expect(result["failed"]?.intValue == 0)
        #expect(result["stoppedAt"]?.isNull == true)
        let rows = try #require(result["results"]?.arrayValue)
        #expect(rows.count == 2)
        #expect(rows[0]["index"]?.intValue == 0)
        #expect(rows[0]["success"]?.boolValue == true)
        #expect(rows[0]["error"]?.isNull == true)
        #expect(rows[0]["resultTruncated"]?.boolValue == false)
        #expect(
            rows[0]["result"]?["structuredContent"]
                == first.structured
        )
        #expect(rows[1]["index"]?.intValue == 1)
        #expect(rows[1]["resultTruncated"]?.boolValue == true)

        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/batch-wire-unstarted"
        )
        let handler = MCPRequestHandler(
            tools: TmuxTools(
                server: server,
                authority: ToolAuthority(toolsets: [.inspect]),
                caller: nil
            )
        )
        let response = try #require(
            handler.toolResponse(
                id: .integer(1),
                outcome: outcome
            )
        )
        #expect(response.utf8.count <= MCPRequestHandler.maximumResponseBytes)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
        #expect(decoded["result"]?["isError"]?.boolValue == false)

        var stopped = ReadBatchAccumulator(total: 2, onError: "stop")
        let stops = stopped.append(tool: "capture_pane", error: "pane disappeared")
        #expect(!stops)
        let stoppedResult = stopped.finish()
        let stoppedRows = try #require(stoppedResult["results"]?.arrayValue)
        #expect(stoppedResult["failed"]?.intValue == 1)
        #expect(stoppedResult["stoppedAt"]?.intValue == 0)
        #expect(stoppedRows[0]["success"]?.boolValue == false)
        #expect(stoppedRows[0]["error"]?.stringValue == "pane disappeared")
        #expect(stoppedRows[0]["result"]?["isError"]?.boolValue == true)

        var continuing = ReadBatchAccumulator(total: 2, onError: "continue")
        let continues = continuing.append(tool: "capture_pane", error: "pane disappeared")
        let acceptsSecond = continuing.append(tool: "list_sessions", outcome: first)
        #expect(continues)
        #expect(acceptsSecond)
        #expect(continuing.finish()["stoppedAt"]?.isNull == true)
    }

    @Test("read batch derives typed schema and capability unions from effective authority")
    func readBatchDerivesEffectiveContract() throws {
        let server = try Server(socketPath: "/tmp/libtmux-swift-test/batch-contract-unstarted")
        let sourceBatch = try #require(TmuxTools.byName["call_read_tools_batch"])
        let excluded = sourceBatch.nestedAuthority.subtracting(["list_sessions"])
        let tools = TmuxTools(
            server: server,
            authority: ServerConfiguration(
                environment: [
                    "LIBTMUX_TOOLSETS": "",
                    "LIBTMUX_TOOLS": "call_read_tools_batch",
                    "LIBTMUX_EXCLUDE_TOOLS": excluded.sorted().joined(separator: ","),
                ]
            ).authority,
            caller: nil
        )
        let batch = try #require(tools.visibleDefinitions.first)
        #expect(batch.nestedAuthority == ["list_sessions"])
        #expect(batch.tmuxEffects == [.observe])
        #expect(batch.outputClasses == [.tmuxMetadata])
        #expect(
            batch.description.hasPrefix(
                "Inspect tmux metadata; accepts no client-supplied executable input."
            )
        )

        let alternatives = try #require(
            batch.inputSchema["properties"]?["operations"]?["items"]?["oneOf"]?.arrayValue
        )
        let operation = try #require(alternatives.first)
        #expect(alternatives.count == 1)
        #expect(operation["properties"]?["tool"]?["const"]?.stringValue == "list_sessions")
        #expect(
            operation["properties"]?["arguments"]
                == TmuxTools.byName["list_sessions"]?.inputSchema
        )

        let disabled = TmuxTools(
            server: server,
            authority: ServerConfiguration(
                environment: [
                    "LIBTMUX_TOOLSETS": "",
                    "LIBTMUX_TOOLS": "call_read_tools_batch",
                    "LIBTMUX_EXCLUDE_TOOLS": sourceBatch.nestedAuthority.sorted()
                        .joined(separator: ","),
                ]
            ).authority,
            caller: nil
        )
        let disabledBatch = try #require(disabled.visibleDefinitions.first)
        #expect(disabledBatch.tmuxEffects == [.observe])
        #expect(disabledBatch.outputClasses.isEmpty)
        #expect(
            disabledBatch.inputSchema["properties"]?["operations"]?["minItems"]?.intValue == 1
        )
        #expect(
            disabledBatch.inputSchema["properties"]?["operations"]?["items"]?["not"]
                == .object([:])
        )
    }

    @Test("startup authenticates exactly one default minimal launcher")
    func startupAuthenticatesDefaultMinimalLauncher() async throws {
        let root = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("owner-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = ServerConfiguration(environment: [:])
        let socketPath = root.appendingPathComponent("server").path
        let firstServer = try Server(
            socketPath: socketPath,
            tmuxExecutable: configuration.tmuxExecutable,
            configurationFile: configuration.tmuxConfigurationFile
        )
        let secondServer = try Server(
            socketPath: socketPath,
            tmuxExecutable: configuration.tmuxExecutable,
            configurationFile: configuration.tmuxConfigurationFile
        )

        let pins: [StartupPin]
        do {
            async let first = configuration.pinForStartup(
                server: firstServer,
                ownerNonce: "11111111111111111111111111111111"
            )
            async let second = configuration.pinForStartup(
                server: secondServer,
                ownerNonce: "22222222222222222222222222222222"
            )
            pins = try await [first, second]
        } catch {
            try? await firstServer.killServer()
            throw error
        }
        let retainedOwner = try? await firstServer.option(
            "@libtmux_mcp_owner",
            scope: .globalSession
        )
        let leakedOwner = try? await firstServer.environmentValue("LIBTMUX_MCP_OWNER")
        let owner = try #require(pins.first(where: { $0.ownsLaunch }))
        let observer = try #require(pins.first(where: { !$0.ownsLaunch }))
        await observer.cleanupOwnedLaunch()
        let survivedObserver = try await firstServer.isRunning()
        await owner.cleanupOwnedLaunch()
        let removedByOwner = !(try await firstServer.isRunning())
        let replacementNonce = "33333333333333333333333333333333"
        let replacementSurvived: Bool
        let retainedReplacementOwner: String?
        do {
            try await firstServer.startServer(
                launchEnvironment: ["LIBTMUX_MCP_OWNER": replacementNonce]
            )
            await owner.cleanupOwnedLaunch()
            retainedReplacementOwner = try await firstServer.option(
                "@libtmux_mcp_owner",
                scope: .globalSession
            )
            replacementSurvived = try await firstServer.isRunning()
            try? await firstServer.killServer()
        } catch {
            try? await firstServer.killServer()
            throw error
        }

        #expect(pins.filter(\.ownsLaunch).count == 1)
        #expect(pins.filter { $0.provenance.configurationProvenance == "minimal" }.count == 1)
        #expect(pins.filter { $0.authority.toolsets.contains(.teardown) }.count == 1)
        #expect(pins.filter { $0.provenance.serverState == "created" }.count == 1)
        #expect(pins.filter { $0.provenance.serverState == "existing" }.count == 1)
        #expect(survivedObserver)
        #expect(removedByOwner)
        #expect(replacementSurvived)
        #expect(retainedReplacementOwner == replacementNonce)
        #expect(leakedOwner == nil)
        #expect(
            retainedOwner.map {
                [
                    "11111111111111111111111111111111",
                    "22222222222222222222222222222222",
                ].contains($0)
            } == true
        )
    }

    @Test("definition schemas validate recursive input before dispatch and every output")
    func definitionSchemasValidateInputAndOutput() async throws {
        let batch = try #require(TmuxTools.byName["call_read_tools_batch"])
        #expect(throws: ToolError.self) {
            _ = try Arguments(
                ToolCall(
                    name: batch.name,
                    arguments: .object([
                        "operations": .array([
                            .object([
                                "tool": .string("capture_pane"),
                                "arguments": .object(["maxLines": .string("many")]),
                            ])
                        ])
                    ])
                ),
                for: batch
            )
        }

        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/output-schema-unstarted"
        )
        let definition = ToolDefinition(
            operation: .listSessions,
            title: "Invalid output fixture",
            descriptionBody: "Return an intentionally invalid test result.",
            toolset: .inspect,
            processReach: .none,
            tmuxEffects: [.observe],
            outputClasses: [.tmuxMetadata],
            arguments: [],
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object(["sessions": .object(["type": .string("array")])]),
                "required": .array([.string("sessions")]),
                "additionalProperties": .bool(false),
            ]),
            inputSinks: [:],
            handler: { _, _, _ in ToolOutcome(structured: .object([:])) }
        )
        let tools = TmuxTools(
            server: server,
            authority: ToolAuthority(toolsets: []),
            caller: nil
        )
        let arguments = try Arguments(ToolCall(name: definition.name), for: definition)
        await #expect(throws: ToolError.self) {
            _ = try await definition.handler(tools, arguments, .silent)
        }
    }

    @Test("the root README names every manifest tool")
    func readmeNamesEveryManifestTool() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(
            contentsOf: repository.appending(path: "README.md"), encoding: .utf8)
        for definition in TmuxTools.definitions {
            #expect(readme.contains("`\(definition.name)`"), Comment(rawValue: definition.name))
        }
    }

    @Test("bounded arguments agree between schemas and readers")
    func boundedArgumentsAgreeBetweenSchemasAndReaders() throws {
        let wait = try #require(TmuxTools.byName["wait_for_text"])
        let patterns = try #require(wait.inputSchema["properties"]?["patterns"])
        #expect(patterns["maxItems"]?.intValue == ToolPattern.maximumListCount)
        #expect(
            patterns["items"]?["x-libtmux-max-utf8-bytes"]?.intValue
                == RegexPattern.maximumSourceUTF8Bytes
        )

        let capture = try #require(TmuxTools.byName["capture_pane"])
        #expect(
            capture.inputSchema["properties"]?["maxLines"]?["maximum"]?.intValue
                == PaneOutputBudget.maximumLines
        )
        let snapshot = try #require(TmuxTools.byName["snapshot_pane"])
        #expect(
            snapshot.inputSchema["properties"]?["maxLines"]?["maximum"]?.intValue
                == PaneOutputBudget.maximumLines
        )
        let run = try #require(TmuxTools.byName["run_shell_command"])
        #expect(
            run.inputSchema["properties"]?["maxLines"]?["maximum"]?.intValue
                == PaneOutputBudget.maximumLines
        )
        #expect(run.inputSchema["properties"]?["timeoutMs"]?["minimum"]?.intValue == 100)
        #expect(run.inputSchema["properties"]?["timeoutMs"]?["maximum"]?.intValue == 600_000)
        #expect(throws: ToolError.self) {
            let arguments = try Arguments(
                ToolCall(
                    name: "capture_pane",
                    arguments: .object([
                        "maxLines": .integer(Int64(PaneOutputBudget.maximumLines + 1)),
                        "paneId": .string("%1"),
                    ])
                ),
                for: capture
            )
            _ = try arguments.optionalInteger("maxLines")
        }
        #expect(throws: ToolError.self) {
            _ = try ToolPattern.compile(
                Array(repeating: String(repeating: "x", count: 4_096), count: 5),
                argument: "patterns"
            )
        }
        let search = try #require(TmuxTools.byName["search_panes"])
        #expect(search.inputSchema["properties"]?["pattern"]?["maxLength"] == nil)
        #expect(
            search.inputSchema["properties"]?["pattern"]?["x-libtmux-max-utf8-bytes"]?
                .intValue == RegexPattern.maximumSourceUTF8Bytes
        )
        #expect(wait.inputSchema["properties"]?["patterns"]?["items"]?["maxLength"] == nil)
        #expect(
            wait.inputSchema["properties"]?["patterns"]?["items"]?[
                "x-libtmux-max-utf8-bytes"]?.intValue
                == RegexPattern.maximumSourceUTF8Bytes
        )
        #expect(
            try ToolPattern.compileLiteral(
                String(repeating: "[", count: RegexPattern.maximumSourceUTF8Bytes),
                argument: "pattern"
            ).containsMatch(in: "no brackets") == false
        )
        #expect(throws: ToolError.self) {
            _ = try ToolPattern.compileLiteral(
                String(repeating: "é", count: RegexPattern.maximumSourceUTF8Bytes / 2 + 1),
                argument: "pattern"
            )
        }
        let sendBatch = try #require(TmuxTools.byName["send_keys_batch"])
        #expect(throws: ToolError.self) {
            let arguments = try Arguments(
                ToolCall(
                    name: "send_keys_batch",
                    arguments: .object([
                        "operations": .array(
                            Array(repeating: .object([:]), count: 65))
                    ])
                ),
                for: sendBatch
            )
            _ = try arguments.array("operations")
        }
    }

    private func nestedOperationSchemas(in definition: ToolDefinition) -> [JSONValue] {
        definition.inputSchema["properties"]?["operations"]?["items"]?["oneOf"]?.arrayValue ?? []
    }

    private func nestedToolNames(in definition: ToolDefinition) -> Set<String> {
        Set(
            nestedOperationSchemas(in: definition).compactMap {
                $0["properties"]?["tool"]?["const"]?.stringValue
            }
        )
    }

    private func result(_ handler: MCPRequestHandler, _ request: String) async throws -> JSONValue {
        let reply = try #require(await handler.respond(to: request))
        let body = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        return try #require(body["result"])
    }
}
