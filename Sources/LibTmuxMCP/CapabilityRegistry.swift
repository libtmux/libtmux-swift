import Foundation
import LibTmux

enum CapabilityRegistryError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

extension TmuxTools {
    private static func argument(
        _ name: String,
        kind: ToolArgument.Kind = .string,
        required: Bool = false,
        allowed: [String] = [],
        minimum: Double? = nil,
        maximum: Double? = nil,
        minimumItems: Int? = nil,
        maximumItems: Int? = nil,
        maximumLength: Int? = nil,
        maximumUTF8Bytes: Int? = nil,
        pattern: String? = nil,
        tmuxFormatControl: TmuxFormatControl? = nil,
        itemSchema: JSONValue? = nil
    ) -> ToolArgument {
        ToolArgument(
            name: name,
            summary: "Caller-controlled \(name).",
            kind: kind,
            isRequired: required,
            allowed: allowed,
            minimum: minimum,
            maximum: maximum,
            minimumItems: minimumItems,
            maximumItems: maximumItems,
            maximumLength: maximumLength,
            maximumUTF8Bytes: maximumUTF8Bytes,
            pattern: pattern,
            itemSchema: itemSchema,
            tmuxFormatControl: tmuxFormatControl
        )
    }

    private static func sinks(
        _ arguments: [ToolArgument],
        special: [String: Set<InputSink>] = [:]
    ) -> [String: Set<InputSink>] {
        precondition(
            Set(arguments.map(\.name)) == Set(special.keys),
            "every caller-controlled input needs an explicit sink classification"
        )
        return Dictionary(
            uniqueKeysWithValues: arguments.map { argument in
                (argument.name, special[argument.name] ?? [])
            })
    }

    private static func makeCapability(
        _ operation: ToolOperation,
        _ title: String,
        _ body: String,
        toolset: Toolset,
        reach: ProcessReach,
        effects: Set<TmuxEffect>,
        outputs: Set<OutputClass>,
        arguments: [ToolArgument] = [],
        specialSinks: [String: Set<InputSink>] = [:],
        nested: Set<String> = [],
        amplifiesFutureInput: Bool = false,
        handler:
            @escaping @Sendable (
                TmuxTools, Arguments, ProgressReporter
            ) async throws -> ToolOutcome
    ) -> ToolDefinition {
        ToolDefinition(
            operation: operation,
            title: title,
            descriptionBody: body,
            toolset: toolset,
            processReach: reach,
            tmuxEffects: effects,
            outputClasses: outputs,
            arguments: arguments,
            outputSchema: CapabilityOutputSchemas.schema(for: operation),
            inputSinks: sinks(arguments, special: specialSinks),
            nestedAuthority: nested,
            amplifiesFutureInput: amplifiesFutureInput,
            handler: handler
        )
    }

    private static func capability(
        _ operation: ToolOperation,
        _ title: String,
        _ body: String,
        toolset: Toolset,
        reach: ProcessReach,
        effects: Set<TmuxEffect>,
        outputs: Set<OutputClass>,
        arguments: [ToolArgument] = [],
        specialSinks: [String: Set<InputSink>] = [:],
        nested: Set<String> = [],
        amplifiesFutureInput: Bool = false,
        handler: @escaping @Sendable (TmuxTools) async throws -> ToolOutcome
    ) -> ToolDefinition {
        makeCapability(
            operation, title, body, toolset: toolset, reach: reach,
            effects: effects, outputs: outputs, arguments: arguments,
            specialSinks: specialSinks, nested: nested,
            amplifiesFutureInput: amplifiesFutureInput,
            handler: { tools, _, _ in try await handler(tools) }
        )
    }

    private static func capability(
        _ operation: ToolOperation,
        _ title: String,
        _ body: String,
        toolset: Toolset,
        reach: ProcessReach,
        effects: Set<TmuxEffect>,
        outputs: Set<OutputClass>,
        arguments: [ToolArgument] = [],
        specialSinks: [String: Set<InputSink>] = [:],
        nested: Set<String> = [],
        amplifiesFutureInput: Bool = false,
        handler: @escaping @Sendable (TmuxTools, Arguments) async throws -> ToolOutcome
    ) -> ToolDefinition {
        makeCapability(
            operation, title, body, toolset: toolset, reach: reach,
            effects: effects, outputs: outputs, arguments: arguments,
            specialSinks: specialSinks, nested: nested,
            amplifiesFutureInput: amplifiesFutureInput,
            handler: { tools, arguments, _ in try await handler(tools, arguments) }
        )
    }

    private static func capability(
        _ operation: ToolOperation,
        _ title: String,
        _ body: String,
        toolset: Toolset,
        reach: ProcessReach,
        effects: Set<TmuxEffect>,
        outputs: Set<OutputClass>,
        arguments: [ToolArgument] = [],
        specialSinks: [String: Set<InputSink>] = [:],
        nested: Set<String> = [],
        amplifiesFutureInput: Bool = false,
        handler:
            @escaping @Sendable (
                TmuxTools, Arguments, ProgressReporter
            ) async throws -> ToolOutcome
    ) -> ToolDefinition {
        makeCapability(
            operation, title, body, toolset: toolset, reach: reach,
            effects: effects, outputs: outputs, arguments: arguments,
            specialSinks: specialSinks, nested: nested,
            amplifiesFutureInput: amplifiesFutureInput, handler: handler
        )
    }

    static let capabilityDefinitions: [ToolDefinition] = {
        let paneID = { argument("paneId", required: true) }
        let windowID = { argument("windowId", required: true) }
        let session = { argument("session", required: true) }
        let integer = { (name: String) in argument(name, kind: .integer) }
        let boolean = { (name: String) in argument(name, kind: .boolean) }
        let noInterpretation: Set<InputSink> = [.none]
        let lookup: Set<InputSink> = [.tmuxLookup]
        let state: Set<InputSink> = [.tmuxState]
        let literalState: Set<InputSink> = [.tmuxState, .tmuxFormat]
        let pattern: Set<InputSink> = [.regex]
        let paneInput: Set<InputSink> = [.paneInput]
        let paneCommand: Set<InputSink> = [.paneInput, .shellCommand]
        let inspectMeta: Set<OutputClass> = [.tmuxMetadata]
        let terminal: Set<OutputClass> = [.tmuxMetadata, .terminalContent]
        let readCallSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "tool": .object(["type": .string("string")]),
                "arguments": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(true),
                ]),
            ]),
            "required": .array([.string("tool")]),
            "additionalProperties": .bool(false),
        ])
        let sendKeysSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "paneId": .object(["type": .string("string")]),
                "keys": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                ]),
                "literal": .object(["type": .string("boolean")]),
                "enter": .object(["type": .string("boolean")]),
                "force": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("paneId"), .string("keys")]),
            "additionalProperties": .bool(false),
        ])

        let rows: [ToolDefinition] = [
            capability(
                .callReadToolsBatch, "Call read tools batch",
                "Invoke a serial batch of at most 16 inspect tools. One client approval covers every nested name; inner tools receive no separate approval. Retained rows contain full nested envelopes; oversized results are marked resultTruncated, and the response stays below the 1,000,000-byte wire cap.",
                toolset: .inspect, reach: .none, effects: [.observe],
                outputs: [
                    .tmuxMetadata, .terminalContent, .processEnvironment, .configuredCommand,
                ],
                arguments: [
                    argument("onError", allowed: ["stop", "continue"]),
                    argument(
                        "operations", kind: .commandArray, required: true, minimumItems: 1,
                        maximumItems: 16,
                        itemSchema: readCallSchema),
                ],
                specialSinks: ["onError": noInterpretation, "operations": [.nestedTool]],
                nested: [
                    "capture_pane", "capture_since", "find_pane_by_position", "get_pane_info",
                    "get_server_info", "get_session_info", "get_tmux_variables",
                    "get_window_info", "list_panes", "list_sessions", "list_windows",
                    "search_panes", "show_environment", "show_hooks", "show_option",
                    "snapshot_pane",
                ],
                handler: { try await $0.callReadToolsBatch($1, $2) }
            ),
            capability(
                .capturePane, "Capture pane", "Return a bounded slice of rendered pane text.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: terminal,
                arguments: [
                    argument("end", kind: .integer, minimum: Double(Int32.min), maximum: 32_767),
                    boolean("joinWrapped"),
                    argument(
                        "maxLines", kind: .integer, minimum: 1,
                        maximum: Double(PaneOutputBudget.maximumLines)),
                    paneID(),
                    argument(
                        "start", kind: .integer, minimum: Double(Int32.min), maximum: 32_767),
                ],
                specialSinks: [
                    "end": state, "joinWrapped": state, "maxLines": noInterpretation,
                    "paneId": lookup, "start": state,
                ],
                handler: { try await $0.capabilityCapturePane($1) }
            ),
            capability(
                .captureSince, "Capture since", "Return output after an opaque pane cursor.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: terminal,
                arguments: [
                    argument("cursor", maximumLength: 16_384),
                    argument(
                        "maxLines", kind: .integer, minimum: 1,
                        maximum: Double(PaneOutputBudget.maximumLines)),
                    paneID(), argument("waitMs", kind: .integer, minimum: 0, maximum: 10_000),
                ],
                specialSinks: [
                    "cursor": noInterpretation, "maxLines": noInterpretation,
                    "paneId": lookup, "waitMs": noInterpretation,
                ],
                handler: { try await $0.capabilityCaptureSince($1) }
            ),
            capability(
                .findPaneByPosition, "Find pane by position",
                "Find a pane occupying a named window corner.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: inspectMeta,
                arguments: [
                    argument(
                        "corner", required: true,
                        allowed: ["top-left", "top-right", "bottom-left", "bottom-right"]),
                    windowID(),
                ],
                specialSinks: ["corner": lookup, "windowId": lookup],
                handler: { try await $0.findPaneByPosition($1) }
            ),
            capability(
                .getPaneInfo, "Get pane info", "Return metadata for one pane.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: inspectMeta,
                arguments: [paneID()], specialSinks: ["paneId": lookup],
                handler: { try await $0.getPaneInfo($1) }
            ),
            capability(
                .getServerInfo, "Get server info",
                "Return liveness and identity metadata for the selected tmux server.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: inspectMeta,
                handler: { try await $0.getServerInfo() }
            ),
            capability(
                .getSessionInfo, "Get session info", "Return metadata for one session.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: inspectMeta,
                arguments: [session()], specialSinks: ["session": lookup],
                handler: { try await $0.getSessionInfo($1) }
            ),
            capability(
                .getTmuxVariables, "Get tmux variables",
                "Resolve validated variable names without accepting raw format syntax.",
                toolset: .inspect, reach: .none, effects: [.observe],
                outputs: [.tmuxMetadata, .configuredCommand],
                arguments: [
                    argument(
                        "names", kind: .stringArray, required: true, maximumItems: 32,
                        tmuxFormatControl: .validatedVariableName,
                        itemSchema: .object([
                            "type": .string("string"),
                            "pattern": .string("^[A-Za-z][A-Za-z0-9_]*$"),
                        ])
                    ),
                    argument("paneId"),
                ],
                specialSinks: ["names": [.tmuxLookup, .tmuxFormat], "paneId": lookup],
                handler: { try await $0.getTmuxVariables($1) }
            ),
            capability(
                .getWindowInfo, "Get window info", "Return metadata and placements for one window.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: inspectMeta,
                arguments: [windowID()], specialSinks: ["windowId": lookup],
                handler: { try await $0.getWindowInfo($1) }
            ),
            capability(
                .listPanes, "List panes", "List panes, optionally within a session or window.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: inspectMeta,
                arguments: [argument("session"), argument("window")],
                specialSinks: ["session": lookup, "window": lookup],
                handler: { try await $0.capabilityListPanes($1) }
            ),
            capability(
                .listSessions, "List sessions", "List sessions on the selected server.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: inspectMeta,
                handler: { try await $0.capabilityListSessions() }
            ),
            capability(
                .listWindows, "List windows", "List windows, optionally within one session.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: inspectMeta,
                arguments: [argument("session")],
                specialSinks: ["session": lookup],
                handler: { try await $0.capabilityListWindows($1) }
            ),
            capability(
                .searchPanes, "Search panes",
                "Search bounded pane content for literal text or a regular expression.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: terminal,
                arguments: [
                    argument(
                        "maxMatchesPerPane", kind: .integer, minimum: 1,
                        maximum: Double(PaneOutputBudget.maximumMatches)),
                    argument(
                        "pattern", required: true,
                        maximumUTF8Bytes: RegexPattern.maximumSourceUTF8Bytes),
                    boolean("regex"),
                    argument(
                        "scrollbackLines", kind: .integer, minimum: 1,
                        maximum: Double(PaneOutputBudget.maximumLines)),
                    argument("session"),
                ],
                specialSinks: [
                    "maxMatchesPerPane": noInterpretation, "pattern": pattern,
                    "regex": noInterpretation, "scrollbackLines": noInterpretation,
                    "session": lookup,
                ],
                handler: { try await $0.capabilitySearchPanes($1, $2) }
            ),
            capability(
                .showEnvironment, "Show environment",
                "Read global or session tmux environment values.",
                toolset: .inspect, reach: .none, effects: [.observe],
                outputs: [.processEnvironment],
                arguments: [argument("session")],
                specialSinks: ["session": lookup],
                handler: { try await $0.capabilityShowEnvironment($1) }
            ),
            capability(
                .showHooks, "Show hooks", "Read configured hooks, optionally for one session.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: [.configuredCommand],
                arguments: [argument("session")], specialSinks: ["session": lookup],
                handler: { try await $0.capabilityShowHooks($1) }
            ),
            capability(
                .showOption, "Show option", "Read one exact tmux option.",
                toolset: .inspect, reach: .none, effects: [.observe],
                outputs: [.tmuxMetadata, .configuredCommand],
                arguments: [
                    argument("name", required: true),
                    argument(
                        "scope",
                        allowed: [
                            "server", "global_session", "global_window", "session", "window",
                            "pane",
                        ]), argument("target"),
                ],
                specialSinks: ["name": lookup, "scope": lookup, "target": lookup],
                handler: { try await $0.capabilityShowOption($1) }
            ),
            capability(
                .snapshotPane, "Snapshot pane",
                "Return pane metadata and bounded terminal content together.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: terminal,
                arguments: [
                    argument(
                        "maxLines", kind: .integer, minimum: 1,
                        maximum: Double(PaneOutputBudget.maximumLines)),
                    paneID(),
                ],
                specialSinks: ["maxLines": noInterpretation, "paneId": lookup],
                handler: { try await $0.snapshotPane($1) }
            ),
            capability(
                .waitForText, "Wait for text", "Wait within one deadline for pane text.",
                toolset: .inspect, reach: .none, effects: [.observe], outputs: terminal,
                arguments: [
                    argument("cursor", maximumLength: 16_384),
                    argument(
                        "maxLines", kind: .integer, minimum: 1,
                        maximum: Double(PaneOutputBudget.maximumLines)),
                    paneID(),
                    argument(
                        "patterns", kind: .stringArray, required: true,
                        maximumItems: ToolPattern.maximumListCount,
                        itemSchema: .object([
                            "type": .string("string"),
                            "x-libtmux-max-utf8-bytes": .number(
                                Double(RegexPattern.maximumSourceUTF8Bytes)),
                        ])),
                    argument(
                        "stop", kind: .stringArray,
                        maximumItems: ToolPattern.maximumListCount,
                        itemSchema: .object([
                            "type": .string("string"),
                            "x-libtmux-max-utf8-bytes": .number(
                                Double(RegexPattern.maximumSourceUTF8Bytes)),
                        ])),
                    boolean("regex"),
                    argument("timeoutMs", kind: .integer, minimum: 100, maximum: 600_000),
                ],
                specialSinks: [
                    "cursor": noInterpretation, "maxLines": noInterpretation,
                    "paneId": lookup, "patterns": pattern, "stop": pattern,
                    "regex": noInterpretation,
                    "timeoutMs": noInterpretation,
                ],
                handler: { try await $0.waitForText($1, $2) }
            ),

            capability(
                .moveWindow, "Move window", "Move one window appearance to another session.",
                toolset: .manage, reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [
                    argument("index", kind: .integer, minimum: 0), argument("session"),
                    argument("sourceIndex", kind: .integer, minimum: 0),
                    argument("sourceSession"), windowID(),
                ],
                specialSinks: [
                    "index": state, "session": lookup, "sourceIndex": lookup,
                    "sourceSession": lookup, "windowId": lookup,
                ], handler: { try await $0.moveWindow($1) }),
            capability(
                .renameSession, "Rename session", "Set a literal-safe session name.",
                toolset: .manage, reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [
                    argument(
                        "name", required: true, tmuxFormatControl: .doubleHashOnce),
                    session(),
                ],
                specialSinks: ["name": literalState, "session": lookup],
                handler: { try await $0.renameSession($1) }),
            capability(
                .renameWindow, "Rename window", "Set a literal-safe window name.", toolset: .manage,
                reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [
                    argument(
                        "name", required: true, tmuxFormatControl: .doubleHashOnce),
                    windowID(),
                ],
                specialSinks: ["name": literalState, "windowId": lookup],
                handler: { try await $0.renameWindow($1) }),
            capability(
                .resizePane, "Resize pane",
                "Resize one pane by dimensions or a directional amount.", toolset: .manage,
                reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [
                    argument("amount", kind: .integer, minimum: 1),
                    argument("direction", allowed: ["up", "down", "left", "right"]),
                    argument("height", kind: .integer, minimum: 1), paneID(),
                    argument("width", kind: .integer, minimum: 1), boolean("zoom"),
                ],
                specialSinks: [
                    "amount": state, "direction": state, "height": state, "paneId": lookup,
                    "width": state, "zoom": state,
                ], handler: { try await $0.capabilityResizePane($1) }),
            capability(
                .resizeWindow, "Resize window",
                "Resize the terminal dimensions reported for one window.", toolset: .manage,
                reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [
                    argument("height", kind: .integer, minimum: 1),
                    argument("width", kind: .integer, minimum: 1), windowID(),
                ],
                specialSinks: ["height": state, "width": state, "windowId": lookup],
                handler: { try await $0.resizeWindow($1) }),
            capability(
                .selectLayout, "Select layout", "Apply one named tmux layout to a window.",
                toolset: .manage, reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [argument("layout", required: true), windowID()],
                specialSinks: ["layout": state, "windowId": lookup],
                handler: { try await $0.capabilitySelectLayout($1) }),
            capability(
                .selectPane, "Select pane", "Select one pane as active.", toolset: .manage,
                reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [paneID()], specialSinks: ["paneId": lookup],
                handler: { try await $0.selectPane($1) }),
            capability(
                .selectWindow, "Select window", "Select one exact window appearance.",
                toolset: .manage, reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [
                    argument("sourceIndex", kind: .integer, minimum: 0),
                    argument("sourceSession"), windowID(),
                ],
                specialSinks: [
                    "sourceIndex": lookup, "sourceSession": lookup, "windowId": lookup,
                ],
                handler: { try await $0.selectWindow($1) }),
            capability(
                .setHistoryLimit, "Set history limit",
                "Set the default retained scrollback line limit.", toolset: .manage, reach: .none,
                effects: [.change], outputs: inspectMeta,
                arguments: [
                    argument(
                        "lines", kind: .integer, required: true, minimum: 0, maximum: 2_000_000)
                ], specialSinks: ["lines": state],
                handler: { try await $0.setHistoryLimit($1) }),
            capability(
                .setMouseEnabled, "Set mouse enabled",
                "Set the global tmux mouse option through a boolean.", toolset: .manage,
                reach: .none, effects: [.change], outputs: inspectMeta,
                arguments: [argument("enabled", kind: .boolean, required: true)],
                specialSinks: ["enabled": state],
                handler: { try await $0.setMouseEnabled($1) }),
            capability(
                .setPaneTitle, "Set pane title", "Set one literal-safe pane title.",
                toolset: .manage, reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [
                    paneID(),
                    argument(
                        "title", required: true, tmuxFormatControl: .doubleHashOnce),
                ],
                specialSinks: ["paneId": lookup, "title": literalState],
                handler: { try await $0.setPaneTitle($1) }),
            capability(
                .signalChannel, "Signal channel", "Signal one tmux wait-for channel.",
                toolset: .manage, reach: .none, effects: [.change], outputs: inspectMeta,
                arguments: [argument("channel", required: true)],
                specialSinks: ["channel": state],
                handler: { try await $0.capabilitySignalChannel($1) }),
            capability(
                .swapPane, "Swap panes", "Swap two panes without changing their identities.",
                toolset: .manage, reach: .none, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [argument("otherPaneId", required: true), paneID()],
                specialSinks: ["otherPaneId": lookup, "paneId": lookup],
                handler: { try await $0.swapPane($1) }),
            capability(
                .waitForChannel, "Wait for channel",
                "Wait within one deadline for a tmux channel signal.", toolset: .manage,
                reach: .none, effects: [.change], outputs: inspectMeta,
                arguments: [
                    argument("channel", required: true, maximumLength: 1_024),
                    argument("timeoutMs", kind: .integer, minimum: 100, maximum: 600_000),
                ],
                specialSinks: ["channel": state, "timeoutMs": noInterpretation],
                handler: { try await $0.capabilityWaitForChannel($1, $2) }),

            capability(
                .createSession, "Create session",
                "Create a detached session with a configured pane process.", toolset: .execute,
                reach: .configuredProcess, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [
                    argument("height", kind: .integer, minimum: 1),
                    argument(
                        "name", required: true, tmuxFormatControl: .doubleHashOnce),
                    argument("startDirectory", tmuxFormatControl: .doubleHashOnce),
                    argument("width", kind: .integer, minimum: 1),
                    argument("windowName", tmuxFormatControl: .doubleHashOnce),
                ],
                specialSinks: [
                    "height": state, "name": literalState, "startDirectory": literalState,
                    "width": state, "windowName": literalState,
                ], handler: { try await $0.createSession($1) }),
            capability(
                .createWindow, "Create window", "Create a window with a configured pane process.",
                toolset: .execute, reach: .configuredProcess, effects: [.observe, .change],
                outputs: inspectMeta,
                arguments: [
                    argument("name", tmuxFormatControl: .doubleHashOnce), session(),
                    argument("startDirectory", tmuxFormatControl: .doubleHashOnce),
                ],
                specialSinks: [
                    "name": literalState, "session": lookup, "startDirectory": literalState,
                ], handler: { try await $0.createWindow($1) }),
            capability(
                .pasteText, "Paste text",
                "Paste literal text and an optional newline target-only after two state checks.",
                toolset: .execute, reach: .paneInput, effects: [.observe, .change],
                outputs: inspectMeta,
                arguments: [
                    boolean("enter"), boolean("force"), paneID(), argument("text", required: true),
                ],
                specialSinks: [
                    "enter": paneInput, "force": noInterpretation, "paneId": lookup,
                    "text": paneInput,
                ],
                handler: { try await $0.capabilityPasteText($1) }),
            capability(
                .respawnPane, "Respawn pane",
                "Restart only the pane's configured process; no caller command is accepted.",
                toolset: .execute, reach: .configuredProcess,
                effects: [.observe, .change, .delete], outputs: inspectMeta,
                arguments: [
                    boolean("force"), boolean("killFirst"), paneID(),
                    argument("startDirectory", tmuxFormatControl: .doubleHashOnce),
                ],
                specialSinks: [
                    "force": noInterpretation, "killFirst": noInterpretation,
                    "paneId": lookup, "startDirectory": literalState,
                ],
                handler: { try await $0.capabilityRespawnPane($1) }),
            capability(
                .runShellCommand, "Run shell command",
                "Run one command in a singular trusted POSIX shell and return bounded output.",
                toolset: .execute, reach: .paneCommand, effects: [.observe, .change],
                outputs: terminal,
                arguments: [
                    argument("command", required: true), boolean("force"),
                    argument(
                        "maxLines", kind: .integer, minimum: 1,
                        maximum: Double(PaneOutputBudget.maximumLines)),
                    paneID(),
                    argument("timeoutMs", kind: .integer, minimum: 100, maximum: 600_000),
                ],
                specialSinks: [
                    "command": paneCommand, "force": noInterpretation,
                    "maxLines": noInterpretation, "paneId": lookup,
                    "timeoutMs": noInterpretation,
                ],
                handler: { try await $0.runShellCommand($1, $2) }),
            capability(
                .sendKeys, "Send keys",
                "Send keys after checking the effective synchronized-pane cohort.",
                toolset: .execute, reach: .paneInput, effects: [.observe, .change],
                outputs: inspectMeta,
                arguments: [
                    boolean("enter"), boolean("force"),
                    argument("keys", kind: .stringArray, required: true), boolean("literal"),
                    paneID(),
                ],
                specialSinks: [
                    "enter": paneInput, "force": noInterpretation, "keys": paneInput,
                    "literal": noInterpretation, "paneId": lookup,
                ], nested: [],
                handler: { try await $0.capabilitySendKeys($1) }),
            capability(
                .sendKeysBatch, "Send keys batch",
                "Send an ordered bounded batch with a fresh check for every row.", toolset: .execute,
                reach: .paneInput, effects: [.observe, .change], outputs: inspectMeta,
                arguments: [
                    argument("onError", allowed: ["stop", "continue"]),
                    argument(
                        "operations", kind: .commandArray, required: true, maximumItems: 64,
                        itemSchema: sendKeysSchema),
                ],
                specialSinks: [
                    "onError": noInterpretation, "operations": [.tmuxLookup, .paneInput],
                ],
                handler: { try await $0.sendKeysBatch($1) }),
            capability(
                .setSynchronizePanes, "Set synchronize panes",
                "Set the window input default; pane overrides determine effective synchronization.",
                toolset: .execute,
                reach: .none, effects: [.change], outputs: inspectMeta,
                arguments: [argument("enabled", kind: .boolean, required: true), windowID()],
                specialSinks: ["enabled": state, "windowId": lookup],
                amplifiesFutureInput: true,
                handler: { try await $0.setSynchronizePanes($1) }),
            capability(
                .splitWindow, "Split window",
                "Create a configured-process pane without accepting command or environment data.",
                toolset: .execute, reach: .configuredProcess, effects: [.observe, .change],
                outputs: inspectMeta,
                arguments: [
                    argument("direction", allowed: ["right", "left", "above", "below"]), paneID(),
                    argument("startDirectory", tmuxFormatControl: .doubleHashOnce),
                ],
                specialSinks: [
                    "direction": state, "paneId": lookup, "startDirectory": literalState,
                ],
                handler: { try await $0.createSplit($1) }),

            capability(
                .clearPaneScrollback, "Clear pane scrollback",
                "Irreversibly discard retained scrollback for one pane.", toolset: .teardown,
                reach: .none, effects: [.delete], outputs: inspectMeta, arguments: [paneID()],
                specialSinks: ["paneId": lookup],
                handler: { try await $0.clearPaneScrollback($1) }),
            capability(
                .killPane, "Kill pane", "Delete one pane and its running process.",
                toolset: .teardown, reach: .none, effects: [.observe, .delete],
                outputs: inspectMeta, arguments: [boolean("force"), paneID()],
                specialSinks: ["force": noInterpretation, "paneId": lookup],
                handler: { try await $0.capabilityKillPane($1) }),
            capability(
                .killSession, "Kill session", "Delete one session and every window it owns.",
                toolset: .teardown, reach: .none, effects: [.observe, .delete],
                outputs: inspectMeta, arguments: [boolean("force"), session()],
                specialSinks: ["force": noInterpretation, "session": lookup],
                handler: { try await $0.capabilityKillSession($1) }),
            capability(
                .killWindow, "Kill window", "Delete one window and every pane it owns.",
                toolset: .teardown, reach: .none, effects: [.observe, .delete],
                outputs: inspectMeta, arguments: [boolean("force"), windowID()],
                specialSinks: ["force": noInterpretation, "windowId": lookup],
                handler: { try await $0.capabilityKillWindow($1) }),
        ]
        let completedRows = rows.map { $0.restrictingNestedAuthority(to: rows) }
        do {
            try validateCapabilityDefinitions(completedRows)
        } catch {
            preconditionFailure("invalid MCP capability registry: \(error)")
        }
        return completedRows
    }()

    static func validateCapabilityDefinitions(_ definitions: [ToolDefinition]) throws {
        let names = definitions.map(\.name)
        guard Set(names).count == names.count else {
            throw CapabilityRegistryError.invalid("duplicate tool name")
        }
        let known = Set(names)
        for definition in definitions {
            guard
                definition.amplifiesFutureInput
                    == (definition.name == "set_synchronize_panes")
            else {
                throw CapabilityRegistryError.invalid(
                    "\(definition.name) has an invalid amplifiesFutureInput claim")
            }
            let schemaKeys = Set(
                definition.inputSchema["properties"]?.objectValue?.keys
                    ?? Dictionary<String, JSONValue>().keys)
            guard schemaKeys == Set(definition.inputSinks.keys) else {
                throw CapabilityRegistryError.invalid(
                    "\(definition.name) input schema and sinks differ")
            }
            guard !definition.tmuxEffects.isEmpty else {
                throw CapabilityRegistryError.invalid("\(definition.name) has no tmux effect")
            }
            for (name, sinks) in definition.inputSinks {
                guard !sinks.isEmpty else {
                    throw CapabilityRegistryError.invalid("\(definition.name).\(name) has no sink")
                }
                if sinks.contains(.tmuxFormat) {
                    let argument = definition.arguments.first { $0.name == name }
                    guard argument?.tmuxFormatControl != nil else {
                        throw CapabilityRegistryError.invalid(
                            "\(definition.name).\(name) has no tmux-format control")
                    }
                } else if definition.arguments.first(where: { $0.name == name })?
                    .tmuxFormatControl != nil
                {
                    throw CapabilityRegistryError.invalid(
                        "\(definition.name).\(name) controls tmux-format without that sink")
                }
            }
            let allSinks = Set(definition.inputSinks.values.flatMap { $0 })
            if definition.nestedAuthority.isEmpty, allSinks.contains(.nestedTool) {
                throw CapabilityRegistryError.invalid(
                    "\(definition.name) has a nested-tool sink without nested authority")
            }
            if !definition.nestedAuthority.isEmpty, !allSinks.contains(.nestedTool) {
                throw CapabilityRegistryError.invalid(
                    "\(definition.name) has nested authority without a nested-tool sink")
            }
            if definition.processReach == .paneInput, !allSinks.contains(.paneInput) {
                throw CapabilityRegistryError.invalid(
                    "\(definition.name) pane-input reach has no sink")
            }
            if definition.processReach == .paneCommand, !allSinks.contains(.shellCommand) {
                throw CapabilityRegistryError.invalid(
                    "\(definition.name) pane-command reach has no sink")
            }
            if definition.processReach == .none || definition.processReach == .configuredProcess {
                guard !allSinks.contains(.paneInput), !allSinks.contains(.shellCommand) else {
                    throw CapabilityRegistryError.invalid(
                        "\(definition.name) reach contradicts sinks")
                }
            }
            if definition.processReach == .configuredProcess, definition.toolset != .execute {
                throw CapabilityRegistryError.invalid(
                    "\(definition.name) configured-process reach is outside execute"
                )
            }
            guard definition.nestedAuthority.isSubset(of: known),
                !definition.nestedAuthority.contains(definition.name)
            else {
                throw CapabilityRegistryError.invalid(
                    "\(definition.name) has invalid nested authority")
            }
            let nestedEffects = Set(
                definitions.filter { definition.nestedAuthority.contains($0.name) }
                    .flatMap(\.tmuxEffects)
            )
            guard nestedEffects.isSubset(of: definition.tmuxEffects) else {
                throw CapabilityRegistryError.invalid(
                    "\(definition.name) omits a nested tool effect")
            }
            let opener = ToolDefinition.controlledOpener(
                toolset: definition.toolset,
                processReach: definition.processReach,
                outputClasses: definition.outputClasses
            )
            guard definition.description.hasPrefix(opener) else {
                throw CapabilityRegistryError.invalid("\(definition.name) lacks controlled opener")
            }
        }
    }
}
