import Foundation

enum TmuxProcessEnvironment {
    static func variables(
        readingFrom environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        environment
    }

    static func controlAttachmentVariables(
        readingFrom environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var variables = environment
        // The endpoint and target are explicit; an outer tmux identity can only
        // trigger nesting checks or misidentify the control client.
        variables["TMUX"] = nil
        variables["TMUX_PANE"] = nil
        return variables
    }
}
