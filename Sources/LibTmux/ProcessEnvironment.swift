import Foundation

enum TmuxProcessEnvironment {
    static func variables(
        readingFrom environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        environment
    }

    static func controlAttachmentVariables(
        for endpoint: Endpoint,
        readingFrom environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var variables = environment
        // The target is explicit, so the pane an outer tmux set can only
        // misidentify the control client.
        variables["TMUX_PANE"] = nil
        // A named endpoint is explicit too, and an outer `TMUX` beside it can
        // only trigger nesting checks. An endpoint that names no socket leaves
        // the choice to tmux, which follows `TMUX`: the connection has to reach
        // the server every other command of this server reaches.
        if endpoint != .tmuxChoice { variables["TMUX"] = nil }
        return variables
    }
}
