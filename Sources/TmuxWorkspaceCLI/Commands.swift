import ArgumentParser

enum ColorMode: String, ExpressibleByArgument, Sendable {
    case auto, always, never
}

struct OutputOptions: ParsableArguments, Sendable {
    @Flag(help: "Write one JSON result.") var json = false
    @Flag(help: "Stream newline-delimited JSON records.") var ndjson = false
    @Option(help: "Color policy for human output.") var color: ColorMode = .auto

    var machine: Bool { json || ndjson }
}

struct SocketOptions: ParsableArguments, Sendable {
    @Option(name: .customShort("S"), help: "tmux socket path.") var path: String?
    @Option(name: .customShort("L"), help: "tmux socket name.") var name: String?

    func validate() throws {
        if path != nil && name != nil {
            throw ValidationError("Choose one of -S and -L.")
        }
    }
}

protocol WorkspaceAction: ParsableCommand, Sendable {
    var output: OutputOptions { get }
}

struct WorkspaceRoot: WorkspaceAction {
    static let configuration = CommandConfiguration(
        commandName: "tmux-workspace",
        abstract: "Manage native tmux workspaces.",
        subcommands: [
            Load.self, Freeze.self, ListWorkspaces.self, Search.self, Convert.self, ImportRoot.self,
        ]
    )
    @OptionGroup var output: OutputOptions
    @Flag(name: [.long, .customShort("V")], help: "Print the package version.")
    var version = false
}

struct Load: WorkspaceAction {
    static let configuration = CommandConfiguration(abstract: "Create workspace sessions.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var socket: SocketOptions
    @Argument(help: "Workspace names or paths.") var files: [String]
    @Option(name: .customShort("f"), help: "tmux configuration file.") var configurationFile:
        String?
    @Option(name: .customShort("s"), help: "Override the final workspace's session name.")
    var sessionName: String?
    @Flag(name: .customShort("d"), help: "Leave loaded sessions detached.") var detached = false
    @Flag(name: [.long, .customShort("y")], help: "Accept confirmations.") var yes = false
    @Flag(help: "Disable the progress display.") var noProgress = false

    mutating func validate() throws {
        guard !files.isEmpty else { throw ValidationError("Provide at least one workspace.") }
        guard detached else {
            throw ValidationError(
                "This build requires load -d; terminal attachment is not implemented yet.")
        }
    }
}

struct Freeze: WorkspaceAction {
    static let configuration = CommandConfiguration(
        abstract: "Capture a live session as a workspace.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var socket: SocketOptions
    @Argument(help: "Exact session name or session ID.") var sessionName: String?
    @Option(name: [.customLong("workspace-format"), .customShort("f")]) var format:
        WorkspaceFormat = .yaml
    @Option(name: [.customLong("save-to"), .customShort("o")]) var destination: String?
    @Flag(name: [.long, .customShort("y")]) var yes = false
    @Flag(name: [.long, .customShort("q")]) var quiet = false
    @Flag(help: "Replace an existing destination file.") var force = false
}

struct ListWorkspaces: WorkspaceAction {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List available workspaces.")
    @OptionGroup var output: OutputOptions
    @Flag(help: "Group human output by directory.") var tree = false
    @Flag(help: "Include the source document in each record.") var full = false
}

struct Search: WorkspaceAction {
    static let configuration = CommandConfiguration(abstract: "Search workspace names and content.")
    @OptionGroup var output: OutputOptions
    @Argument var terms: [String]
    @Option(name: [.customShort("f"), .long]) var field: [String] = []
    @Flag(name: [.customShort("i"), .long]) var ignoreCase = false
    @Flag(name: [.customShort("S"), .long]) var smartCase = false
    @Flag(name: [.customShort("F"), .long]) var fixedStrings = false
    @Flag(name: [.customShort("w"), .long]) var wordRegexp = false
    @Flag(name: [.customShort("v"), .long]) var invertMatch = false
    @Flag var any = false

    mutating func validate() throws {
        guard !terms.isEmpty else { throw ValidationError("Provide a search pattern.") }
    }
}

enum WorkspaceFormat: String, ExpressibleByArgument, Sendable {
    case yaml, json
}

struct Convert: WorkspaceAction {
    static let configuration = CommandConfiguration(
        abstract: "Convert a workspace between YAML and JSON.")
    @OptionGroup var output: OutputOptions
    @Argument var file: String
    @Flag(name: [.long, .customShort("y")]) var yes = false
}

struct SaveOptions: ParsableArguments, Sendable {
    @Option(name: .customLong("save-to"), help: "Save to this destination instead of stdout.")
    var destination: String?
    @Option(name: .customLong("workspace-format"), help: "Saved document encoding.")
    var format: WorkspaceFormat = .yaml
    @Flag(help: "Replace an existing destination.") var force = false
}

struct ImportRoot: WorkspaceAction {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Import a workspace from another tmux manager.",
        subcommands: [ImportTeamocil.self, ImportTmuxinator.self])
    @OptionGroup var output: OutputOptions
}

protocol ImportAction: WorkspaceAction {
    var file: String { get }
    var save: SaveOptions { get }
    static var importer: String { get }
}

struct ImportTeamocil: ImportAction {
    static let importer = "teamocil"
    static let configuration = CommandConfiguration(
        commandName: "teamocil", abstract: "Translate a teamocil workspace.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var save: SaveOptions
    @Argument(help: "Source path or name in ~/.teamocil.") var file: String
}

struct ImportTmuxinator: ImportAction {
    static let importer = "tmuxinator"
    static let configuration = CommandConfiguration(
        commandName: "tmuxinator",
        abstract: "Translate a tmuxinator workspace without executing ERB.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var save: SaveOptions
    @Argument(help: "Source path or name in TMUXINATOR_CONFIG or ~/.tmuxinator.") var file: String
}
