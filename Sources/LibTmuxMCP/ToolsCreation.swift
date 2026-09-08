import LibTmux

extension TmuxTools {
    func newSession(_ arguments: Arguments) async throws -> ToolOutcome {
        let session = try await server.newSession(
            named: try arguments.string("name"),
            startDirectory: try arguments.optionalString("startDirectory"),
            windowName: try arguments.optionalString("windowName"),
            width: try arguments.optionalInteger("width"),
            height: try arguments.optionalInteger("height")
        )
        return .init(SessionResult(session))
    }
}
