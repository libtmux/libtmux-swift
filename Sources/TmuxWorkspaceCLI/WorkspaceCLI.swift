import ArgumentParser
import Dispatch
import Foundation
import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

struct CLIContext: Sendable {
    var directory: URL
    var environment: [String: String]
    var output: @Sendable (String) async throws -> Void
    var error: @Sendable (String) async throws -> Void
    var terminal = false
}

@main
enum WorkspaceCLI {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        do {
            let output = try NonblockingLineWriter(fileDescriptor: STDOUT_FILENO)
            let error = try NonblockingLineWriter(fileDescriptor: STDERR_FILENO)
            let context = CLIContext(
                directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                environment: ProcessInfo.processInfo.environment,
                output: { line in try await write(line, with: output) },
                error: { line in try await write(line, with: error) },
                terminal: isatty(STDOUT_FILENO) == 1
            )
            let task = Task {
                await run(Array(CommandLine.arguments.dropFirst()), context: context)
            }
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let interrupts = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { task.cancel() }
                source.resume()
                return source
            }
            let status = await task.value
            for source in interrupts { source.cancel() }
            exit(status)
        } catch { exit(1) }
    }

    static func run(_ arguments: [String], context: CLIContext) async -> Int32 {
        let raw = arguments.prefix { $0 != "--" }
        let machine = raw.contains("--json") || raw.contains("--ndjson")
        let action: any WorkspaceAction
        do {
            var parsed = try WorkspaceRoot.parseAsRoot(arguments)
            guard let command = parsed as? any WorkspaceAction else {
                try parsed.run()
                return 0
            }
            action = command
        } catch {
            let status = WorkspaceRoot.exitCode(for: error).rawValue
            let message = WorkspaceRoot.fullMessage(for: error)
            if status == 0 {
                try? await context.output(message)
            } else {
                await diagnostic(
                    CLIError("usage", message, status: 2), machine: machine, context: context)
            }
            return status == 0 ? 0 : 2
        }
        let output = Presenter(options: action.output, context: context)
        do {
            switch action {
            case let command as WorkspaceRoot:
                if command.version {
                    try await output.result(
                        .object([
                            "name": .string("tmux-workspace"),
                            "version": .string(LibTmuxVersion.current),
                        ]))
                } else if command.output.machine {
                    throw CLIError("usage", "Choose a workspace command or --version.", status: 2)
                } else {
                    try await context.output(WorkspaceRoot.helpMessage())
                }
            case let command as ListWorkspaces:
                try await ReadCommands.list(command, context: context, output: output)
            case let command as Search:
                try await ReadCommands.search(command, context: context, output: output)
            case let command as Convert:
                try await ReadCommands.convert(command, context: context, output: output)
            case let command as Load:
                try await WorkspaceCommands.load(command, context: context, output: output)
            case let command as Freeze:
                try await WorkspaceCommands.freeze(command, context: context, output: output)
            case let command as any ImportAction:
                try await ImportCommands.run(command, context: context, output: output)
            case let command as Edit:
                return try await ProcessCommands.edit(command, context: context, output: output)
            case let command as DebugInfo:
                try await ProcessCommands.diagnostics(command, context: context, output: output)
            case let command as Shell:
                return try await ProcessCommands.shell(command, context: context, output: output)
            case is ImportRoot:
                throw CLIError("usage", "Choose import teamocil or import tmuxinator.", status: 2)
            default: throw CLIError("usage", "Choose a workspace command.", status: 2)
            }
            return 0
        } catch {
            let failure =
                error as? CLIError
                ?? CLIError(
                    Task.isCancelled ? "cancelled" : "operation", String(describing: error),
                    status: Task.isCancelled ? 130 : 1)
            await output.failure(failure)
            return failure.status
        }
    }

    fileprivate static func diagnostic(_ error: CLIError, machine: Bool, context: CLIContext) async
    {
        let value = Value.object([
            "severity": .string("error"), "code": .string(error.code),
            "message": .string(error.message),
        ])
        try? await context.error(
            machine ? value.encoded() : "Error: \(Presenter.sanitize(error.message))")
    }

    private static func write(_ line: String, with writer: NonblockingLineWriter) async throws {
        switch await writer.write(line) {
        case .written: return
        case .cancelled: throw CancellationError()
        case .closed: throw CLIError("closed_output", "Output pipe closed.")
        case let .failed(code): throw CLIError("output", "Output failed (errno \(code)).")
        }
    }
}

struct CLIError: Error, Sendable, CustomStringConvertible {
    let code: String
    let message: String
    var status: Int32 = 1
    init(_ code: String, _ message: String, status: Int32 = 1) {
        self.code = code
        self.message = message
        self.status = status
    }
    var description: String { message }
}

actor Presenter {
    let options: OutputOptions
    let context: CLIContext
    private var sequence = 0
    private var logFile: FileHandle?

    init(options: OutputOptions, context: CLIContext) {
        self.options = options
        self.context = context
    }

    func result(_ value: Value) async throws {
        try await context.output(value.encoded(pretty: !options.machine))
    }

    func document(_ value: Value, command: String) async throws {
        if options.ndjson {
            try await result(
                .object([
                    "schema_version": .integer(1), "command": .string(command),
                    "status": .string("success"), "workspace": value,
                ]))
        } else {
            try await result(value)
        }
    }

    func event(_ event: String, command: String, data: Value) async throws {
        await log(
            event == "failed" ? .error : .info,
            fields: ["event": .string(event), "command": .string(command), "data": data])
        guard options.ndjson else { return }
        sequence += 1
        try await result(
            .object([
                "schema_version": .integer(1), "sequence": .integer(Int64(sequence)),
                "command": .string(command), "event": .string(event), "data": data,
            ]))
    }

    func row(_ value: Value, tree: Bool = false) async throws {
        if options.machine {
            try await result(value)
            return
        }
        let name = Self.sanitize(value["name"]?.string ?? "")
        let path = Self.sanitize(value["path"]?.string ?? "")
        let colored =
            !(context.environment["NO_COLOR"] ?? "").isEmpty
            ? false
            : options.color == .always
                || (options.color == .auto
                    && (context.terminal || !(context.environment["FORCE_COLOR"] ?? "").isEmpty))
        let line =
            colored ? "\u{1b}[1;36m\(name)\u{1b}[0m  \u{1b}[2m\(path)\u{1b}[0m" : "\(name)  \(path)"
        try await context.output(tree ? "  " + line : line)
    }

    func warning(_ message: String, code: String = "capture_loss") async throws {
        await log(.warning, fields: ["code": .string(code), "message": .string(message)])
        guard options.logLevel.priority <= DiagnosticLevel.warning.priority else { return }
        let value = Value.object([
            "severity": .string("warning"), "code": .string(code),
            "message": .string(message),
        ])
        try await context.error(
            options.machine ? value.encoded() : "Warning: \(Self.sanitize(message))")
    }

    func failure(_ error: CLIError) async {
        await log(.error, fields: ["code": .string(error.code), "message": .string(error.message)])
        await WorkspaceCLI.diagnostic(error, machine: options.machine, context: context)
    }

    func openLog(_ file: URL) throws {
        guard !file.path.utf8.contains(0) else {
            throw CLIError("log_open", "Log file path contains a NUL byte.")
        }
        let descriptor = open(
            file.path, O_WRONLY | O_CREAT | O_APPEND | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw CLIError("log_open", String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw CLIError("log_open", "Log destination must be a regular file.")
        }
        logFile = handle
    }

    private func log(_ level: DiagnosticLevel, fields: [String: Value]) async {
        guard let file = logFile, level.priority >= options.logLevel.priority else { return }
        var record = fields
        record["schema_version"] = .integer(1)
        record["severity"] = .string(level.rawValue)
        do {
            try file.write(contentsOf: Data((try Value.object(record).encoded() + "\n").utf8))
        } catch {
            logFile = nil
            try? file.close()
            await WorkspaceCLI.diagnostic(
                CLIError("log_write", "Cannot append to the log file: \(error)"),
                machine: options.machine, context: context)
        }
    }

    static func sanitize(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            scalar.value < 32 || (127...159).contains(scalar.value)
                ? String(format: "\\u%04x", scalar.value) : String(scalar)
        }.joined()
    }
}
