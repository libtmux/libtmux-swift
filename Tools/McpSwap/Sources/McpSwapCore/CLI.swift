import Foundation

struct StatusRequest: Equatable, Sendable {
    var repo: URL
    var server: String?
    var clients: [ClientName]
    var scope: Scope?
}

struct DoctorRequest: Equatable, Sendable {
    var repo: URL
    var server: String?
}

enum CLIInvocation: Equatable, Sendable {
    case help(String?)
    case detect
    case status(StatusRequest)
    case use(UseRequest)
    case revert(RevertRequest)
    case doctor(DoctorRequest)
}

enum CLIParser {
    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        guard let command = arguments.first else { return .help(nil) }
        if command == "--help" || command == "-h" { return .help(nil) }
        let tail = Array(arguments.dropFirst())
        if tail.contains("--help") || tail.contains("-h") { return .help(command) }
        switch command {
        case "detect":
            guard tail.isEmpty else { throw unknown(tail[0], command: command) }
            return .detect
        case "status": return .status(try parseStatus(tail))
        case "use-local": return .use(try parseUse(tail))
        case "revert": return .revert(try parseRevert(tail))
        case "doctor": return .doctor(try parseDoctor(tail))
        default: throw SwapError.message("unknown command \(command.debugDescription)")
        }
    }

    static func help(command: String?) -> String {
        switch command {
        case "detect":
            return """
                Usage: mcp-swap detect

                List all eight supported clients and report binary/config presence.
                """
        case "status":
            return """
                Usage: mcp-swap status [--repo PATH] [--server NAME] [--cli CLIENT] [--scope user|project]

                Show the current MCP server entry. Repeat --cli or use comma-separated names.
                Claude can show independent user and project scopes; other clients are global.
                """
        case "use-local":
            return """
                Usage: mcp-swap use-local [options]

                  --repo PATH             Repository root (default: .)
                  --pr N                  Use git+REMOTE@refs/pull/N/head through uvx
                  --flavour VALUE         dev, debug, release, or installed (default: dev)
                  --no-preflight          Skip the MCP initialize round trip
                  --server NAME           Override the Package.swift-derived server name
                  --entry COMMAND         Override the executable product/entry name
                  --env KEY=VALUE         Preserve existing env, then set this value; repeatable
                  --cli CLIENT            Limit clients; repeat or comma-separate values
                  --scope user|project    Claude scope (default: project; global for others)
                  --dry-run               Plan and print a diff without locks, probes, or writes
                """
        case "revert":
            return """
                Usage: mcp-swap revert [--cli CLIENT] [--scope user|project] [--dry-run]

                Restore top-contiguous recovery layers. With no Claude scope, unwind both in LIFO order.
                """
        case "doctor":
            return """
                Usage: mcp-swap doctor [--repo PATH] [--server NAME]

                Report entries, strict Swift recovery state, orphaned Swift backups, and auth overrides.
                """
        default:
            return """
                Usage: mcp-swap <command> [options]

                Safely point MCP client configs at this Swift checkout or a pull request.

                Commands:
                  detect      List supported client binary/config presence
                  status      Show current MCP entries
                  use-local   Transactionally replace entries
                  revert      Restore recorded layers in LIFO order
                  doctor      Diagnose entries, recovery, backups, and auth env

                Run `mcp-swap <command> --help` for command options.
                """
        }
    }

    private static func parseStatus(_ arguments: [String]) throws -> StatusRequest {
        var reader = ArgumentReader(arguments)
        var repo = URL(fileURLWithPath: ".")
        var server: String?
        var selectors: [String] = []
        var scope: Scope?
        while let option = reader.next() {
            switch option {
            case "--repo": repo = URL(fileURLWithPath: try reader.value(for: option))
            case "--server": server = try reader.value(for: option)
            case "--cli": selectors.append(try reader.value(for: option))
            case "--scope": scope = try parseScope(reader.value(for: option))
            default: throw unknown(option, command: "status")
            }
        }
        return StatusRequest(
            repo: repo.standardizedFileURL,
            server: server,
            clients: try selectClientNames(selectors),
            scope: scope)
    }

    private static func parseUse(_ arguments: [String]) throws -> UseRequest {
        var reader = ArgumentReader(arguments)
        var request = UseRequest(repo: URL(fileURLWithPath: "."))
        var selectors: [String] = []
        while let option = reader.next() {
            switch option {
            case "--repo": request.repo = URL(fileURLWithPath: try reader.value(for: option))
            case "--pr":
                let raw = try reader.value(for: option)
                guard let value = Int(raw), value > 0 else {
                    throw SwapError.message("--pr expects a positive integer")
                }
                request.pullRequest = value
            case "--flavour":
                let raw = try reader.value(for: option)
                guard let value = SourceFlavor(rawValue: raw) else {
                    throw SwapError.message("unknown --flavour \(raw.debugDescription)")
                }
                request.flavor = value
            case "--no-preflight": request.noPreflight = true
            case "--server": request.server = try reader.value(for: option)
            case "--entry": request.entry = try reader.value(for: option)
            case "--env":
                let raw = try reader.value(for: option)
                guard let separator = raw.firstIndex(of: "="), separator != raw.startIndex else {
                    throw SwapError.message("--env expects KEY=VALUE")
                }
                let key = String(raw[..<separator])
                guard key != "LIBTMUX_SAFETY" else {
                    throw SwapError.message(
                        "LIBTMUX_SAFETY has been removed; use LIBTMUX_TOOLSETS")
                }
                request.environment[key] = String(raw[raw.index(after: separator)...])
            case "--cli": selectors.append(try reader.value(for: option))
            case "--scope": request.scope = try parseScope(reader.value(for: option))
            case "--dry-run": request.dryRun = true
            default: throw unknown(option, command: "use-local")
            }
        }
        request.repo = request.repo.standardizedFileURL
        request.clients = try selectClientNames(selectors)
        return request
    }

    private static func parseRevert(_ arguments: [String]) throws -> RevertRequest {
        var reader = ArgumentReader(arguments)
        var selectors: [String] = []
        var request = RevertRequest()
        while let option = reader.next() {
            switch option {
            case "--cli": selectors.append(try reader.value(for: option))
            case "--scope": request.scope = try parseScope(reader.value(for: option))
            case "--dry-run": request.dryRun = true
            default: throw unknown(option, command: "revert")
            }
        }
        request.clients = try selectClientNames(selectors)
        return request
    }

    private static func parseDoctor(_ arguments: [String]) throws -> DoctorRequest {
        var reader = ArgumentReader(arguments)
        var repo = URL(fileURLWithPath: ".")
        var server: String?
        while let option = reader.next() {
            switch option {
            case "--repo": repo = URL(fileURLWithPath: try reader.value(for: option))
            case "--server": server = try reader.value(for: option)
            default: throw unknown(option, command: "doctor")
            }
        }
        return DoctorRequest(repo: repo.standardizedFileURL, server: server)
    }

    private static func parseScope(_ raw: String) throws -> Scope {
        guard let value = Scope(rawValue: raw) else {
            throw SwapError.message("scope must be 'user' or 'project'")
        }
        return value
    }

    private static func unknown(_ option: String, command: String) -> SwapError {
        .message("unknown option \(option.debugDescription) for \(command)")
    }
}

public enum CommandRunner {
    public static func run(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdout: (String) -> Void = { print($0) },
        stderr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) -> Int32 {
        do {
            let invocation = try CLIParser.parse(arguments)
            if case .help(let command) = invocation {
                stdout(CLIParser.help(command: command))
                return 0
            }
            let roots = try Roots.discover(environment: environment)
            let lookup: (String) -> URL? = { executableOnPath($0, environment: environment) }
            let engine = SwapEngine(
                roots: roots,
                environment: environment,
                executableLookup: lookup,
                preflightAction: { _, _, spec in
                    try preflight(spec, baseEnvironment: environment)
                })
            switch invocation {
            case .help: return 0
            case .detect:
                renderDetect(roots: roots, lookup: lookup, stdout: stdout)
            case .status(let request):
                try renderStatus(
                    request, roots: roots, lookup: lookup, stdout: stdout, stderr: stderr)
            case .use(let request):
                render(
                    try engine.use(request), dryRun: request.dryRun,
                    stdout: stdout, stderr: stderr)
            case .revert(let request):
                render(
                    try engine.revert(request), dryRun: request.dryRun,
                    stdout: stdout, stderr: stderr)
            case .doctor(let request):
                try renderDoctor(
                    request, roots: roots, engine: engine,
                    environment: environment, stdout: stdout)
            }
            return 0
        } catch {
            stderr(String(describing: error))
            return 1
        }
    }
}

private struct ArgumentReader {
    let arguments: [String]
    var index = 0

    init(_ arguments: [String]) { self.arguments = arguments }

    mutating func next() -> String? {
        guard index < arguments.count else { return nil }
        defer { index += 1 }
        return arguments[index]
    }

    mutating func value(for option: String) throws -> String {
        guard let value = next(), !value.hasPrefix("--") else {
            throw SwapError.message("\(option) requires a value")
        }
        return value
    }
}

private func renderDetect(
    roots: Roots,
    lookup: (String) -> URL?,
    stdout: (String) -> Void
) {
    for client in knownClients(roots: roots) {
        let binary = lookup(client.binary) != nil
        let config = FileManager.default.fileExists(atPath: client.configPath.path)
        let present = binary && config ? "yes" : " no"
        var missing: [String] = []
        if !binary { missing.append("binary missing") }
        if !config { missing.append("config missing: \(client.configPath.path)") }
        var adapterIsDirectory = ObjCBool(false)
        let adapter = roots.home.appending(
            path: ".pi/agent/npm/node_modules/pi-mcp-adapter")
        if client.name == .pi,
            !FileManager.default.fileExists(
                atPath: adapter.path, isDirectory: &adapterIsDirectory)
                || !adapterIsDirectory.boolValue
        {
            missing.append("needs the pi-mcp-adapter package; pi has no built-in MCP client")
        }
        let suffix = missing.isEmpty ? "" : "  (\(missing.joined(separator: ", ")))"
        stdout("  [\(present)] \(client.name.rawValue)\(suffix)")
    }
}

private func renderStatus(
    _ request: StatusRequest,
    roots: Roots,
    lookup: (String) -> URL?,
    stdout: (String) -> Void,
    stderr: (String) -> Void
) throws {
    let metadata = try resolveRepoMetadata(repo: request.repo)
    let server = request.server ?? metadata.server
    let catalog = knownClients(roots: roots)
    let targets =
        request.clients.isEmpty
        ? catalog.filter {
            lookup($0.binary) != nil && FileManager.default.fileExists(atPath: $0.configPath.path)
        }
        : catalog.filter { request.clients.contains($0.name) }
    for client in targets {
        guard FileManager.default.fileExists(atPath: client.configPath.path) else {
            stdout("[\(client.name.rawValue)] no config at \(client.configPath.path)")
            continue
        }
        do {
            let bytes = try stableRead(client.configPath)
            let scopes: [Scope] =
                client.name == .claude
                ? request.scope.map { [$0] } ?? Scope.allCases
                : [.user]
            var shown = false
            for scope in scopes {
                guard
                    let spec = try ConfigCodec.readServer(
                        client: client,
                        bytes: bytes,
                        server: server,
                        repo: request.repo,
                        scope: scope)
                else { continue }
                shown = true
                stdout(
                    "[\(statusLabel(client.name, scope))] \(server) = \(spec.command) \(spec.arguments.joined(separator: " "))  (\(describe(spec, repo: request.repo)))"
                )
            }
            if !shown {
                let outputLabel =
                    client.name == .claude && request.scope != nil
                    ? statusLabel(client.name, request.scope!) : client.name.rawValue
                stdout("[\(outputLabel)] no entry for \(server.debugDescription)")
            }
        } catch { stderr("[\(client.name.rawValue)] \(error)") }
    }
}

private func render(
    _ report: OperationReport,
    dryRun: Bool,
    stdout: (String) -> Void,
    stderr: (String) -> Void
) {
    for message in report.messages { stdout(message) }
    for change in report.changes {
        if dryRun {
            stdout(diff(change))
        } else if let backup = change.backup {
            stdout("[\(change.label)] \(change.action); backup: \(backup.path)")
        } else {
            stdout("[\(change.label)] \(change.action)")
        }
    }
    for warning in report.warnings { stderr("warning: \(warning)") }
}

private func renderDoctor(
    _ request: DoctorRequest,
    roots: Roots,
    engine: SwapEngine,
    environment: [String: String],
    stdout: (String) -> Void
) throws {
    let server: String
    if let requested = request.server {
        server = requested
    } else {
        server = try resolveRepoMetadata(repo: request.repo).server
    }
    stdout("mcp-swap doctor")
    stdout("  repo:   \(request.repo.path)")
    stdout("  server: \(server)")
    stdout("  entries by client:")
    var repoNames = Set<String>()
    for client in knownClients(roots: roots)
    where FileManager.default.fileExists(atPath: client.configPath.path) {
        do {
            let bytes = try stableRead(client.configPath)
            let entries = try ConfigCodec.servers(client: client, bytes: bytes, repo: request.repo)
            for entry in entries where entry.name == server {
                stdout(
                    "    [\(statusLabel(client.name, entry.scope))] \(server) = \(describe(entry.spec, repo: request.repo))"
                )
            }
            for entry in entries
            where entry.spec.localRepository?.path == request.repo.standardizedFileURL.path {
                repoNames.insert(entry.name)
                if entry.name != server {
                    stdout(
                        "    [\(statusLabel(client.name, entry.scope))] \(entry.name) = local: this repo  (other name)"
                    )
                }
            }
        } catch { stdout("    [\(client.name.rawValue)] config unreadable: \(error)") }
    }
    if repoNames.isEmpty {
        stdout("    (no client currently points at this repo)")
    } else if !repoNames.contains(server) {
        let names = repoNames.sorted()
        stdout(
            "  ! server name mismatch: this repo is registered as \(names), not \(server.debugDescription) — use --server \(names[0])"
        )
    }
    let ledger = try engine.validatedRecoveryLedger()
    if !ledger.entries.isEmpty {
        stdout("  outstanding swaps:")
        for entry in ledger.entries.values.sorted(by: { $0.sequence < $1.sequence }) {
            stdout("    \(entry.key)  swapped_at=\(entry.swappedAt)")
        }
    }
    let referenced = Set(ledger.entries.values.map { $0.backupPath.path })
    var orphans = Set<String>()
    for client in knownClients(roots: roots) {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: client.configPath.deletingLastPathComponent(),
                includingPropertiesForKeys: nil)
        else { continue }
        for url in contents
        where url.lastPathComponent.hasPrefix(
            client.configPath.lastPathComponent + ".bak.mcp-swap-swift-")
            && !referenced.contains(url.path)
        {
            orphans.insert(url.path)
        }
    }
    if !orphans.isEmpty {
        stdout("  orphaned Swift backups: \(orphans.count) — inspect before deleting")
    }
    let auth: [(String, ClientName)] = [
        ("ANTHROPIC_API_KEY", .claude), ("OPENAI_API_KEY", .codex),
        ("GEMINI_API_KEY", .gemini), ("GOOGLE_API_KEY", .gemini),
        ("XAI_API_KEY", .grok), ("GROK_API_KEY", .grok),
    ]
    for (variable, client) in auth where environment[variable]?.isEmpty == false {
        stdout("  ! \(variable) overrides \(client.rawValue)'s stored login")
    }
}

private func stableRead(_ url: URL) throws -> Data {
    let route = try FileRoute.capture(logical: url)
    let data = try Data(contentsOf: route.resolved)
    guard SHA256.hex(data) == route.target.digest else {
        throw SwapError.message("\(url.path) changed while it was read")
    }
    try route.verify()
    return data
}

private func describe(_ spec: ServerSpec, repo: URL) -> String {
    if let pullRequest = spec.pullRequest {
        return "PR #\(pullRequest.number): \(pullRequest.url)"
    }
    if spec.command == "swift", spec.arguments.contains(repo.path) {
        return "local: this repo"
    }
    if spec.command.hasPrefix(repo.path + "/") { return "local: this repo" }
    if spec.command == "uvx" {
        let pin = spec.arguments.first { $0.contains("==") || $0.contains("@") }
        return pin.map { "package pin: \($0)" } ?? "package (unpinned)"
    }
    return "other"
}

private func diff(_ change: OperationChange) -> String {
    let before = String(decoding: change.before, as: UTF8.self)
    let after = String(decoding: change.after, as: UTF8.self)
    var lines = ["--- \(change.path.path) (current)", "+++ \(change.path.path) (proposed)"]
    lines += before.split(separator: "\n", omittingEmptySubsequences: false).map { "-\($0)" }
    lines += after.split(separator: "\n", omittingEmptySubsequences: false).map { "+\($0)" }
    return lines.joined(separator: "\n")
}

private func statusLabel(_ client: ClientName, _ scope: Scope) -> String {
    client == .claude ? "\(client.rawValue):\(scope.rawValue)" : client.rawValue
}
