enum CapabilityOutputSchemas {
    private static let string: JSONValue = .object(["type": .string("string")])
    private static let integer: JSONValue = .object(["type": .string("integer")])
    private static let number: JSONValue = .object(["type": .string("number")])
    private static let boolean: JSONValue = .object(["type": .string("boolean")])
    private static let nullableString: JSONValue = .object([
        "type": .array([.string("string"), .string("null")])
    ])
    private static let nullableInteger: JSONValue = .object([
        "type": .array([.string("integer"), .string("null")])
    ])

    private static func array(_ item: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": item])
    }

    private static func object(
        _ properties: [String: JSONValue],
        required: Set<String>? = nil
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(
                (required ?? Set(properties.keys)).sorted().map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func map(_ value: JSONValue) -> JSONValue {
        .object(["type": .string("object"), "additionalProperties": value])
    }

    private static let session = object([
        "ref": string, "id": string, "name": string, "windowCount": integer,
        "isAttached": boolean, "createdAt": integer,
    ])
    private static let window = object([
        "ref": string, "id": string, "name": string, "paneCount": integer,
        "width": integer, "height": integer,
    ])
    private static let windowLink = object([
        "ref": string, "sessionID": string, "windowID": string, "index": integer,
        "isActive": boolean, "target": string,
    ])
    private static let windowOccurrence = object([
        "windowRef": string, "linkRef": string, "id": string, "name": string,
        "paneCount": integer, "width": integer, "height": integer, "sessionID": string,
        "index": integer, "isActive": boolean, "target": string,
    ])
    private static let pane = object([
        "ref": string, "id": string, "index": integer, "width": integer,
        "height": integer, "isActive": boolean, "currentCommand": string,
        "currentPath": string, "isAtTop": boolean, "isAtBottom": boolean,
        "isAtLeft": boolean, "isAtRight": boolean, "windowID": string,
    ])
    private static let capture = object([
        "paneId": string, "lines": array(string), "droppedLines": integer,
    ])
    private static let deletedPane = object(["paneId": string, "deleted": boolean])
    private static let deletedWindow = object(["windowId": string, "deleted": boolean])
    private static let deletedSession = object(["sessionId": string, "deleted": boolean])

    static func schema(for operation: ToolOperation) -> JSONValue {
        switch operation {
        case .listSessions:
            object(["sessions": array(session)])
        case .listWindows:
            object(["windows": array(windowOccurrence)])
        case .listPanes:
            object(["panes": array(pane)])
        case .getServerInfo:
            object(
                ["running": boolean, "version": string, "socketPath": string],
                required: ["running"]
            )
        case .getSessionInfo:
            object(["session": session])
        case .getWindowInfo:
            object(["window": window, "placements": array(windowLink)])
        case .getPaneInfo, .findPaneByPosition, .enterCopyMode, .exitCopyMode:
            object(["pane": pane])
        case .capturePane:
            capture
        case .captureSince:
            object([
                "paneRef": string, "pane": string, "lines": array(string), "cursor": string,
                "linesMissed": boolean, "restarted": boolean, "droppedLines": integer,
            ])
        case .snapshotPane:
            object(["pane": pane, "capture": capture])
        case .searchPanes:
            object([
                "matches": array(
                    object([
                        "paneRef": string, "pane": string, "line": integer, "text": string,
                    ])),
                "panesSearched": integer, "panesAvailable": integer, "truncated": boolean,
                "truncatedBy": array(string),
            ])
        case .waitForText:
            object([
                "paneRef": string, "outcome": string, "matched": nullableString,
                "matchedIndex": nullableInteger, "sawNewOutput": boolean,
                "matchedAtEntry": boolean, "tail": array(string), "seconds": number,
                "cursor": nullableString, "effectiveTimeout": number,
            ])
        case .getTmuxVariables:
            object(["values": map(nullableString)])
        case .showOption:
            object(["options": array(object(["name": string, "value": string]))])
        case .showEnvironment:
            object(["environment": map(nullableString)])
        case .showHooks:
            object([
                "hooks": array(object(["name": string, "index": integer, "command": string]))
            ])
        case .callReadToolsBatch:
            object([
                "results": array(
                    object([
                        "index": integer,
                        "tool": string,
                        "success": boolean,
                        "error": nullableString,
                        "result": .object([
                            "type": .array([.string("object"), .string("null")]),
                            "properties": .object([
                                "content": array(object(["type": string, "text": string])),
                                "structuredContent": .object([:]),
                                "isError": boolean,
                            ]),
                            "required": .array([
                                .string("content"), .string("structuredContent"),
                                .string("isError"),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                        "resultTruncated": boolean,
                    ])),
                "onError": string,
                "succeeded": integer,
                "failed": integer,
                "stoppedAt": nullableInteger,
                "truncated": boolean,
                "truncatedBytes": integer,
            ])
        case .moveWindow, .selectWindow:
            object(["windowId": string, "target": string])
        case .renameSession:
            object(["sessionId": string, "name": string])
        case .renameWindow:
            object(["windowId": string, "name": string])
        case .resizePane, .selectPane:
            object(["paneId": string])
        case .resizeWindow:
            object(["windowId": string])
        case .selectLayout:
            object(["windowId": string, "layout": string])
        case .setHistoryLimit:
            object(["lines": integer])
        case .setMouseEnabled:
            object(["enabled": boolean])
        case .setPaneTitle:
            object(["paneId": string, "title": string])
        case .signalChannel:
            object(["channel": string, "signalled": boolean])
        case .swapPane:
            object(["paneId": string, "otherPaneId": string])
        case .waitForChannel:
            object([
                "channel": string, "released": boolean, "seconds": number,
                "effectiveTimeout": number,
            ])
        case .createSession:
            session
        case .createWindow:
            windowOccurrence
        case .splitWindow:
            pane
        case .pasteText:
            object(["paneRef": string, "pane": string, "characters": integer])
        case .respawnPane:
            object(["paneRef": string, "pane": string])
        case .runShellCommand:
            object([
                "paneRef": string, "pane": string, "exitStatus": nullableInteger,
                "timedOut": boolean, "output": array(string), "linesMissed": boolean,
                "droppedLines": integer, "seconds": number, "effectiveTimeout": number,
            ])
        case .sendKeys:
            object([
                "paneRef": string, "pane": string, "keys": array(string),
                "resolvedPaneIds": array(string),
            ])
        case .sendKeysBatch:
            object([
                "completed": integer,
                "failures": array(object(["index": integer, "reason": string])),
                "targets": array(
                    object(["index": integer, "resolvedPaneIds": array(string)])),
            ])
        case .setSynchronizePanes:
            object(["windowId": string, "enabled": boolean])
        case .clearPaneScrollback, .killPane:
            deletedPane
        case .killWindow:
            deletedWindow
        case .killSession:
            deletedSession
        }
    }
}
