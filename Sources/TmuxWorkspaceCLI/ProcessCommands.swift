import Foundation
import LibTmux
import Subprocess

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

enum ProcessCommands {
    static func edit(_ command: Edit, context: CLIContext, output: Presenter) async throws -> Int32
    {
        let file = try DocumentStore(context: context).resolve(command.file)
        var arguments = try splitArguments(context.environment["EDITOR"] ?? "vi")
        guard !arguments.isEmpty, !arguments[0].isEmpty else {
            throw CLIError("editor", "EDITOR must name an executable.", status: 2)
        }
        arguments.append(file.path)
        let result = try await run(
            arguments, context: context, terminal: context.terminal && !command.output.machine)
        if command.output.machine {
            try await output.result(
                .object([
                    "schema_version": .integer(1), "command": .string("edit"),
                    "status": .string(result.code == 0 ? "success" : "error"),
                    "path": .string(file.path), "exit_code": .integer(Int64(result.code)),
                    "stdout": .string(result.output), "stderr": .string(result.error),
                ]))
        } else {
            if !result.output.isEmpty {
                try await context.output(Presenter.sanitize(result.output))
            }
            if !result.error.isEmpty { try await context.error(Presenter.sanitize(result.error)) }
        }
        return result.code
    }

    static func diagnostics(
        _ command: DebugInfo, context: CLIContext, output: Presenter
    ) async throws {
        let store = DocumentStore(context: context)
        let binary = context.environment["LIBTMUX_TMUX_BIN"] ?? "tmux"
        var tmux: [String: Value] = ["executable": .string(mask(binary, context: context))]
        do {
            let result = try await run([binary, "-V"], context: context)
            tmux["available"] = .bool(result.code == 0)
            tmux["version"] = .string(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            tmux["exit_code"] = .integer(Int64(result.code))
        } catch {
            try Task.checkCancellation()
            tmux["available"] = .bool(false)
        }
        var environment: [String: Value] = [:]
        for name in ["SHELL", "TERM", "TMUX", "TMUX_PANE", "TMUXP_CONFIGDIR", "XDG_CONFIG_HOME"] {
            if let value = context.environment[name] {
                environment[name] = .string(mask(value, context: context))
            }
        }
        try await output.result(
            .object([
                "schema_version": .integer(1), "command": .string("debug-info"),
                "port": .string("swift"), "version": .string(LibTmuxVersion.current),
                "platform": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                "tmux": .object(tmux), "environment": .object(environment),
                "workspace_directories": .array(
                    store.globalDirectories.map {
                        .string(mask($0.path, context: context))
                    }),
            ]))
    }

    private static func mask(_ value: String, context: CLIContext) -> String {
        guard let home = context.environment["HOME"], !home.isEmpty, home != "/" else {
            return value
        }
        return value.replacingOccurrences(of: home, with: "~")
    }

    static func splitArguments(_ value: String) throws -> [String] {
        var result: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in value {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
                started = true
            } else if character == quote {
                quote = nil
            } else if quote == nil && (character == "'" || character == "\"") {
                quote = character
                started = true
            } else if quote == nil && character.isWhitespace {
                if started {
                    result.append(word)
                    word = ""
                    started = false
                }
            } else {
                word.append(character)
                started = true
            }
        }
        guard quote == nil && !escaped else {
            throw CLIError(
                "command_argv", "Command contains an unfinished quote or escape.", status: 2)
        }
        if started { result.append(word) }
        return result
    }

    struct Result: Sendable {
        let code: Int32
        var output = ""
        var error = ""
    }

    static func run(
        _ arguments: [String], context: CLIContext, terminal: Bool = false
    ) async throws -> Result {
        guard let executable = arguments.first, !executable.isEmpty else {
            throw CLIError("command_argv", "Command must name an executable.", status: 2)
        }
        var environment: [Subprocess.Environment.Key: String] = [:]
        for (key, value) in context.environment {
            guard let name = Subprocess.Environment.Key(rawValue: key) else {
                throw CLIError("environment", "Invalid environment variable name.")
            }
            environment[name] = value
        }
        var options = PlatformOptions()
        options.createSession = !terminal
        options.teardownSequence = [
            .send(signal: .kill, toProcessGroup: !terminal, allowedDurationToNextStep: .zero)
        ]
        let configuration = Subprocess.Configuration(
            executable: executable.contains("/")
                ? .path(FilePath(DocumentStore(context: context).path(executable).path))
                : .name(executable),
            arguments: Arguments(Array(arguments.dropFirst())), environment: .custom(environment),
            workingDirectory: FilePath(context.directory.path), platformOptions: options)
        if terminal {
            // The presenter shares these open file descriptions with the child.
            let descriptors = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].map {
                ($0, fcntl($0, F_GETFL))
            }
            defer {
                for (descriptor, flags) in descriptors where flags >= 0 {
                    _ = fcntl(descriptor, F_SETFL, flags)
                }
            }
            for (descriptor, flags) in descriptors where flags >= 0 {
                guard fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) != -1 else {
                    throw CLIError("terminal", "Cannot restore blocking terminal input/output.")
                }
            }
            let result = try await Subprocess.run(
                configuration, input: .currentStandardInput,
                output: .currentStandardOutput, error: .currentStandardError)
            try Task.checkCancellation()
            return Result(code: exitCode(result.terminationStatus))
        }
        let result = try await Subprocess.run(
            configuration, input: .none, output: .data(limit: 1_048_576),
            error: .data(limit: 1_048_576))
        try Task.checkCancellation()
        return Result(
            code: exitCode(result.terminationStatus),
            output: String(decoding: result.standardOutput, as: UTF8.self),
            error: String(decoding: result.standardError, as: UTF8.self))
    }

    private static func exitCode(_ status: TerminationStatus) -> Int32 {
        switch status {
        case let .exited(code): Int32(code)
        case let .signaled(number): 128 + Int32(number)
        }
    }
}
