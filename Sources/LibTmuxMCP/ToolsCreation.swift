import LibTmux
import TmuxWorkspace

extension TmuxTools {
    func newSession(_ arguments: Arguments) async throws -> ToolOutcome {
        let session = try await server.newSession(
            named: try arguments.string("name"),
            startDirectory: try arguments.optionalString("start_directory"),
            windowName: try arguments.optionalString("window_name")
        )
        return .init(SessionResult(session))
    }

    func newWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let session = try WireReferenceCodec.processLocal.resolve(
            target,
            among: try await server.sessions(),
            argument: "target",
            refreshWith: "list_sessions"
        )
        let appearance = try await server.newWindow(
            in: session,
            named: try arguments.optionalString("name"),
            startDirectory: try arguments.optionalString("start_directory")
        )
        return .init(WindowOccurrenceResult(window: appearance.window, link: appearance.link))
    }

    func splitPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let direction: PaneDirection =
            switch try arguments.string("direction", or: "below") {
            case "right": .right
            case "above": .above
            case "left": .left
            default: .below
            }
        let created = try await server.split(
            pane,
            direction: direction,
            startDirectory: try arguments.optionalString("start_directory")
        )
        return .init(PaneResult(created))
    }

    func applyWorkspace(_ arguments: Arguments) async throws -> ToolOutcome {
        guard let plan = try arguments.document("plan") else {
            throw ToolError.missingArgument("plan")
        }
        let workspace = try Workspace.decode(json: plan)
        let session = try await WorkspaceBuilder.build(workspace, on: server)
        let snapshot = try await server.snapshot()
        guard session.incarnation == snapshot.incarnation else {
            throw TmuxError.serverRestarted
        }
        let links = snapshot.windowLinks(of: session)
        return .init(
            WorkspaceResult(
                session: SessionResult(session),
                windows: WindowOccurrenceResult.projecting(
                    snapshot.windows(of: session),
                    through: links
                ),
                panes: snapshot.panes(of: session).map { PaneResult($0) }
            )
        )
    }
}
