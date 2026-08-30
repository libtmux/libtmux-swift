import LibTmux

/// The stable protocol name of an MCP tool.
public enum ToolOperation: String, Sendable, Hashable, CaseIterable {
    case describeServer = "describe_server"
    case describeFilters = "describe_filters"
    case listServers = "list_servers"
    case showOptions = "show_options"
    case showEnvironment = "show_environment"
    case showHooks = "show_hooks"
    case listSessions = "list_sessions"
    case listWindows = "list_windows"
    case listPanes = "list_panes"
    case snapshot
    case capturePane = "capture_pane"
    case captureSince = "capture_since"
    case searchPanes = "search_panes"
    case readFormat = "read_format"
    case waitForOutput = "wait_for_output"
    case watchFormat = "watch_format"
    case waitForChannel = "wait_for_channel"
    case signalChannel = "signal_channel"
    case runShell = "run_shell"
    case sendKeys = "send_keys"
    case newSession = "new_session"
    case newWindow = "new_window"
    case splitPane = "split_pane"
    case applyWorkspace = "apply_workspace"
    case setOption = "set_option"
    case setEnvironment = "set_environment"
    case rename
    case select
    case resizePane = "resize_pane"
    case selectLayout = "select_layout"
    case respawnPane = "respawn_pane"
    case pasteText = "paste_text"
    case killPane = "kill_pane"
    case killWindow = "kill_window"
    case killSession = "kill_session"
    case killServer = "kill_server"
    case runCommand = "run_command"
    case runCommands = "run_commands"

    func execute(
        on tools: TmuxTools,
        arguments: Arguments,
        reporting progress: ProgressReporter
    ) async throws -> ToolOutcome {
        switch self {
        case .describeServer: return try await tools.describeServer()
        case .describeFilters: return .init(FilterSchema.current)
        case .listServers: return try await tools.listServers(arguments)
        case .showOptions: return try await tools.showOptions(arguments)
        case .showEnvironment: return try await tools.showEnvironment(arguments)
        case .showHooks: return try await tools.showHooks(arguments)

        case .listSessions: return try await tools.listSessions(arguments)
        case .listWindows: return try await tools.listWindows(arguments)
        case .listPanes: return try await tools.listPanes(arguments)
        case .snapshot: return try await tools.readSnapshot()
        case .capturePane: return try await tools.capturePane(arguments)
        case .captureSince: return try await tools.captureSince(arguments)
        case .searchPanes: return try await tools.searchPanes(arguments, progress)
        case .readFormat: return try await tools.readFormat(arguments)

        case .waitForOutput: return try await tools.waitForOutput(arguments, progress)
        case .watchFormat: return try await tools.watchFormat(arguments, progress)
        case .waitForChannel: return try await tools.waitForChannel(arguments, progress)
        case .signalChannel: return try await tools.signalChannel(arguments)

        case .runShell: return try await tools.runShell(arguments, progress)
        case .sendKeys: return try await tools.sendKeys(arguments)
        case .newSession: return try await tools.newSession(arguments)
        case .newWindow: return try await tools.newWindow(arguments)
        case .splitPane: return try await tools.splitPane(arguments)
        case .applyWorkspace: return try await tools.applyWorkspace(arguments)
        case .setOption: return try await tools.setOption(arguments)
        case .setEnvironment: return try await tools.setEnvironment(arguments)
        case .rename: return try await tools.rename(arguments)
        case .select: return try await tools.select(arguments)
        case .resizePane: return try await tools.resizePane(arguments)
        case .selectLayout: return try await tools.selectLayout(arguments)
        case .respawnPane: return try await tools.respawnPane(arguments)
        case .pasteText: return try await tools.pasteText(arguments)

        case .killPane: return try await tools.killPane(arguments)
        case .killWindow: return try await tools.killWindow(arguments)
        case .killSession: return try await tools.killSession(arguments)
        case .killServer: return try await tools.killServer(arguments)

        case .runCommand: return try await tools.runCommand(arguments)
        case .runCommands: return try await tools.runCommands(arguments)
        }
    }
}
