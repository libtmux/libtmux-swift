import ArgumentParser
import Dispatch
import Foundation
import LibTmux
import TmuxWorkspace

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
    var inputTTY: String?
    var input: (@Sendable () async throws -> String?)?
    var errorTerminal = false
    var terminalSize = (columns: 80, rows: 24)
    /// stdout's own size, when it is a terminal — distinct from
    /// `terminalSize` (read from stderr, for the progress panel). `nil` when
    /// stdout is not a terminal or the kernel reports no size for it.
    var stdoutSize: (columns: Int, rows: Int)?
    var rawOutput: (@Sendable (String) async throws -> Void)?
    var rawError: (@Sendable (String) async throws -> Void)?
}

/// Carries an interrupt that arrived before the work task existed.
///
/// Installing the signal sources first and adopting the task afterwards means
/// no signal can reach the default disposition once this process has started.
final class InterruptRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Int32, Never>?
    private var interrupted = false

    func cancel() {
        lock.lock()
        interrupted = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func adopt(_ task: Task<Int32, Never>) {
        lock.lock()
        self.task = task
        let interrupted = self.interrupted
        lock.unlock()
        if interrupted { task.cancel() }
    }
}

@main
enum WorkspaceCLI {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let relay = InterruptRelay()
        let interrupts = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable in relay.cancel() }
            source.resume()
            return source
        }
        do {
            let output = try NonblockingLineWriter(fileDescriptor: STDOUT_FILENO)
            let error = try NonblockingLineWriter(fileDescriptor: STDERR_FILENO)
            var size = winsize()
            _ = ioctl(STDERR_FILENO, UInt(TIOCGWINSZ), &size)
            var stdoutSizeRaw = winsize()
            let stdoutSize: (columns: Int, rows: Int)? =
                ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &stdoutSizeRaw) == 0
                    && stdoutSizeRaw.ws_col > 0 && stdoutSizeRaw.ws_row > 0
                ? (columns: Int(stdoutSizeRaw.ws_col), rows: Int(stdoutSizeRaw.ws_row)) : nil
            let inputTTY =
                isatty(STDIN_FILENO) == 1 && tcgetpgrp(STDIN_FILENO) == getpgrp()
                ? ttyname(STDIN_FILENO).map { String(cString: $0) } : nil
            let context = CLIContext(
                directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                environment: ProcessInfo.processInfo.environment,
                output: { line in try await write(line, with: output) },
                error: { line in try await write(line, with: error) },
                terminal: isatty(STDOUT_FILENO) == 1,
                inputTTY: inputTTY,
                input: { try await ProcessCommands.readLine() },
                errorTerminal: isatty(STDERR_FILENO) == 1,
                terminalSize: (
                    columns: size.ws_col > 0 ? Int(size.ws_col) : 80,
                    rows: size.ws_row > 0 ? Int(size.ws_row) : 24
                ),
                stdoutSize: stdoutSize,
                rawOutput: { text in try await write(text, with: output, newline: false) },
                rawError: { text in try await write(text, with: error, newline: false) }
            )
            let task = Task {
                await run(Array(CommandLine.arguments.dropFirst()), context: context)
            }
            relay.adopt(task)
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
            // `.message(for:)`, not `.fullMessage(for:)`: the full form already
            // carries its own "Error: " prefix and a usage block joined by
            // real newlines, and diagnostic() below would double both.
            let message = WorkspaceRoot.message(for: error)
            if status == 0 {
                try? await context.output(message)
                return 0
            }
            await diagnostic(
                CLIError("usage", message, status: 2), machine: machine, context: context)
            return 2
        }
        let output = Presenter(options: action.output, context: context)
        do {
            switch action {
            case let command as WorkspaceRoot:
                if command.version {
                    if command.output.machine {
                        try await output.result(
                            .object([
                                "name": .string("tmux-workspace"),
                                "version": .string(LibTmuxVersion.current),
                            ]))
                    } else {
                        try await context.output("tmux-workspace \(LibTmuxVersion.current)")
                    }
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
                    canonicalCode(for: error), message(for: error), status: status(for: error))
            await output.failure(failure)
            return failure.status
        }
    }

    fileprivate static func diagnostic(_ error: CLIError, machine: Bool, context: CLIContext) async
    {
        let value = Value.object([
            "schema_version": .integer(1), "code": .string(error.code),
            "message": .string(error.message),
        ])
        try? await context.error(
            machine ? value.encoded() : "Error: \(Presenter.sanitize(error.message))")
    }

    /// The machine error code for a condition where the error's own
    /// `CLIError.code` was not already written to match the shared table the
    /// other six ports use. Conditions this does not recognise keep their
    /// own lower-snake-case code.
    static func canonicalCode(for error: any Error) -> String {
        if Task.isCancelled || error is CancellationError { return "interrupted" }
        if let error = error as? WorkspaceBuilderError { return canonicalCode(for: error) }
        if let error = error as? TmuxError { return canonicalCode(for: error) }
        if let error = error as? CLIError { return error.code }
        return "operation"
    }

    /// The exit status a failure asks for, which a callback's own `CLIError`
    /// keeps through the builder that carried it.
    static func status(for error: any Error) -> Int32 {
        if Task.isCancelled || error is CancellationError { return 130 }
        if let error = error as? CLIError { return error.status }
        guard let error = error as? WorkspaceBuilderError else { return 1 }
        switch error {
        case let .callback(inner): return status(for: inner)
        case let .rollbackFailed(original, _): return status(for: original)
        default: return 1
        }
    }

    private static func canonicalCode(for error: WorkspaceBuilderError) -> String {
        switch error {
        case .noWindows: return "invalid_workspace"
        case .sessionExists: return "session_exists"
        case .sessionVanished: return "tmux_failed"
        case let .tmux(inner): return canonicalCode(for: inner)
        case let .callback(inner): return canonicalCode(for: inner)
        case let .rollbackFailed(original, _): return canonicalCode(for: original)
        }
    }

    private static func canonicalCode(for error: TmuxError) -> String {
        switch error {
        // tmux itself could not be reached: no such executable, or the
        // socket/endpoint it names is unusable.
        case .processLaunchFailed, .invalidEndpoint: return "tmux_unavailable"
        default: return "tmux_failed"
        }
    }

    /// A plain sentence for an error no `CLIError` site recognised, instead
    /// of `String(describing:)`'s Swift enum literal.
    static func message(for error: any Error) -> String {
        if let error = error as? WorkspaceBuilderError { return message(for: error) }
        if let error = error as? TmuxError { return message(for: error) }
        if let error = error as? CLIError { return error.message }
        return String(describing: error)
    }

    private static func message(for error: WorkspaceBuilderError) -> String {
        switch error {
        case .noWindows:
            return "The workspace has no windows."
        case let .sessionExists(name):
            return "A session named \(name) already exists."
        case let .sessionVanished(name):
            return "Session \(name) disappeared while the workspace was being built."
        case let .tmux(inner):
            return message(for: inner)
        case let .callback(inner):
            return message(for: inner)
        case let .rollbackFailed(original, cleanup):
            return
                "\(message(for: original)) Rolling back the partial session also failed: \(message(for: cleanup))"
        }
    }

    private static func message(for error: TmuxError) -> String {
        switch error {
        case let .processLaunchFailed(reason): return reason
        case .requestNotSubmitted: return "The command was never sent to tmux."
        case let .invocationFailed(reason): return reason
        case let .commandTooLarge(actualBytes, maximumBytes):
            return "The command was \(actualBytes) bytes, over the \(maximumBytes)-byte limit."
        case let .commandFailed(command, exitCode, reason):
            return reason.isEmpty
                ? "\(command) failed (exit \(exitCode))"
                : "\(command) failed (exit \(exitCode)): \(reason)"
        case let .outputLimitExceeded(perStreamBytes):
            return "tmux's reply exceeded the \(perStreamBytes)-byte-per-stream limit."
        case let .invalidEndpoint(reason):
            switch reason {
            case .empty: return "The tmux endpoint is empty."
            case let .socketPathTooLong(actualBytes, maximumBytes):
                return
                    "The socket path is \(actualBytes) bytes, over the \(maximumBytes)-byte limit."
            }
        case let .decodingFailed(reason):
            switch reason {
            case let .fieldCountMismatch(rowIndex, expected, actual):
                return "tmux row \(rowIndex) had \(actual) fields, expected \(expected)."
            case let .invalidEncoding(rowIndex):
                return "tmux row \(rowIndex) was not valid UTF-8."
            case let .invalidValue(rowIndex, field, raw):
                return "tmux row \(rowIndex) field \(field) had an invalid value: \(raw)"
            }
        case .serverRestarted:
            return "The tmux server restarted while the request was in flight."
        case .foreignServerValue:
            return "That value belongs to a different tmux server."
        case .staleServerValue:
            return "That target no longer exists."
        case .cancelled:
            return "Cancelled."
        case .connectionClosed:
            return "The control connection closed while a command was still waiting."
        case let .notificationBufferOverflow(limit):
            return "More than \(limit) control notifications arrived unread."
        case .outputContinuityLost:
            return "Pane output could not be read continuously; some lines may have been missed."
        }
    }

    private static func write(
        _ line: String, with writer: NonblockingLineWriter, newline: Bool = true
    ) async throws {
        switch await writer.write(line, newline: newline) {
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
    private var progress: LoadProgress?

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
        if ["failed", "completed", "workspace-completed"].contains(event) {
            progress?.update(event, data: data)
            await finishProgress()
        } else if progress != nil {
            progress?.update(event, data: data)
            try await drawProgress()
        }
        guard options.ndjson else { return }
        sequence += 1
        // Fields sit at the top level, not nested under `data`.
        var envelope: [String: Value] = [
            "schema_version": .integer(1), "sequence": .integer(Int64(sequence)),
            "command": .string(command), "event": .string(event),
        ]
        if case let .object(fields) = data {
            envelope.merge(fields) { existing, _ in existing }
        } else if data != .null {
            envelope["data"] = data
        }
        try await result(.object(envelope))
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
        await finishProgress()
        await log(.error, fields: ["code": .string(error.code), "message": .string(error.message)])
        await Self.finalOutput { [options, context] in
            await WorkspaceCLI.diagnostic(error, machine: options.machine, context: context)
        }
    }

    func failedLoad(_ value: Value) async {
        await Self.finalOutput {
            try await self.event("failed", command: "load", data: value)
            if self.options.json && !self.options.ndjson {
                try await self.result(value)
            }
        }
    }

    func prepareProgress(_ command: Load) throws {
        progress = try LoadProgress.create(command, context: context)
    }

    func bootstrap(_ text: String, stream: String) async throws {
        let code = "bootstrap_" + stream
        if options.machine {
            try await warning(text, code: code)
            return
        }
        await log(.warning, fields: ["code": .string(code), "message": .string(text)])
        await finishProgress()
        let sink =
            stream == "stdout"
            ? context.rawOutput ?? context.output : context.rawError ?? context.error
        try await sink(text)
        if progress?.active == true, !text.hasSuffix("\n") {
            try await (context.rawError ?? context.error)("\n")
        }
        progress?.appendCapturedOutput(text)
        try await drawProgress()
    }

    private func drawProgress() async throws {
        guard let frame = progress?.frame() else { return }
        try await (context.rawError ?? context.error)(frame)
    }

    private func finishProgress() async {
        guard let clear = progress?.clear(), !clear.isEmpty else { return }
        let sink = context.rawError ?? context.error
        await Self.finalOutput { try await sink(clear) }
    }

    private static func finalOutput(_ operation: @escaping @Sendable () async throws -> Void) async
    {
        let cleanup = Task.detached { try await operation() }
        let deadline = Task.detached {
            do {
                try await Task.sleep(for: .milliseconds(200))
                cleanup.cancel()
            } catch {}
        }
        _ = try? await cleanup.value
        deadline.cancel()
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
            await finishProgress()
            await WorkspaceCLI.diagnostic(
                CLIError("log_write", "Cannot append to the log file: \(error)"),
                machine: options.machine, context: context)
        }
    }

    static func sanitize(_ value: String) -> String {
        sanitize(value, preservingLines: false)
    }

    static func sanitizeChildOutput(_ value: String) -> String {
        sanitize(value, preservingLines: true)
    }

    private static func sanitize(_ value: String, preservingLines: Bool) -> String {
        value.unicodeScalars.map { scalar in
            let control = scalar.value < 32 || (127...159).contains(scalar.value)
            let lineSpace = preservingLines && (scalar.value == 9 || scalar.value == 10)
            return control && !lineSpace ? String(format: "\\u%04x", scalar.value) : String(scalar)
        }.joined()
    }
}
