import Foundation
import LibTmux

// The tools that change something.

extension TmuxTools {
    func sendKeys(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let keys = try arguments.strings("keys")
        guard !keys.isEmpty else { throw ToolError.missingArgument("keys") }
        try await server.sendKeys(
            keys,
            to: pane,
            literally: try arguments.bool("literal", or: false)
        )
        return .init(
            SentKeys(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue,
                keys: keys
            )
        )
    }

    func rename(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let name = try arguments.string("name")
        let references = WireReferenceCodec.processLocal
        let snapshot = try await server.snapshot()
        switch try references.checkedKind(
            of: target,
            argument: "target",
            refreshWith: "list_sessions, list_windows, or snapshot"
        ) {
        case .window:
            let window = try references.resolve(
                target,
                among: snapshot.windows,
                argument: "target",
                refreshWith: "list_windows or snapshot"
            )
            try await server.rename(window, to: name)
            return .init(
                Renamed(
                    ref: references.reference(to: window),
                    kind: "window",
                    id: window.id.rawValue,
                    name: name
                )
            )
        case .session:
            let session = try references.resolve(
                target,
                among: snapshot.sessions,
                argument: "target",
                refreshWith: "list_sessions"
            )
            try await server.rename(session, to: name)
            return .init(
                Renamed(
                    ref: references.reference(to: session),
                    kind: "session",
                    id: session.id.rawValue,
                    name: name
                )
            )
        default:
            throw ToolError.wrongArgumentType(
                "target",
                expected: "a session ref or global windowRef"
            )
        }
    }

    func select(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let references = WireReferenceCodec.processLocal
        let snapshot = try await server.snapshot()
        switch try references.checkedKind(
            of: target,
            argument: "target",
            refreshWith: "list_panes or list_windows"
        ) {
        case .pane:
            let pane = try references.resolve(
                target,
                among: snapshot.panes,
                argument: "target",
                refreshWith: "list_panes"
            )
            try await server.select(pane)
            return .init(
                Killed(
                    ref: references.reference(to: pane),
                    kind: "pane",
                    id: pane.id.rawValue
                )
            )
        case .windowLink:
            let link = try references.resolve(
                target,
                among: snapshot.windowLinks,
                argument: "target",
                refreshWith: "list_windows"
            )
            try await server.select(link)
            return .init(
                Killed(
                    ref: references.reference(to: link),
                    kind: "window-link",
                    id: link.target
                )
            )
        default:
            throw ToolError.wrongArgumentType(
                "target",
                expected: "a pane ref or exact window linkRef"
            )
        }
    }

    func resizePane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let width = try arguments.optionalInteger("width")
        let height = try arguments.optionalInteger("height")
        guard width != nil || height != nil else {
            throw ToolError.missingArgument("width or height")
        }
        try await server.resize(pane, width: width, height: height)
        let after = try WireReferenceCodec.processLocal.resolve(
            WireReferenceCodec.processLocal.reference(to: pane),
            among: try await server.panes(),
            argument: "pane",
            refreshWith: "list_panes"
        )
        return .init(
            Resized(
                paneRef: WireReferenceCodec.processLocal.reference(to: after),
                pane: after.id.rawValue,
                width: after.width,
                height: after.height
            )
        )
    }

    func selectLayout(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let window = try WireReferenceCodec.processLocal.resolve(
            target,
            among: try await server.windows(),
            argument: "target",
            refreshWith: "list_windows or snapshot"
        )
        let layout = try arguments.string("layout")
        try await server.selectLayout(window, layout)
        return .init(
            LaidOut(
                windowRef: WireReferenceCodec.processLocal.reference(to: window),
                window: window.id.rawValue,
                layout: layout
            )
        )
    }

    func pasteText(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let text = try arguments.string("text")
        // Named per call and deleted after: tmux's paste buffers are shared
        // with the user's own, and leaving one behind puts this text into a
        // history they will page through later.
        let buffer = "libtmux-mcp-\(UUID().uuidString.prefix(8))"
        try await server.setBuffer(text, named: buffer)
        let paste: Result<Void, TmuxError>
        do {
            try await server.paste(buffer: buffer, into: pane)
            paste = .success(())
        } catch {
            paste = .failure(error)
        }
        let cleanup = Task {
            try await server.deleteBuffer(named: buffer)
        }
        try await cleanup.value
        try paste.get()
        return .init(
            Pasted(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue,
                characters: text.count
            )
        )
    }
}
