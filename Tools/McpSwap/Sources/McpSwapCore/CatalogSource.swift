import Foundation

enum SwapError: Error, Equatable, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): text
        }
    }
}

enum ClientName: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case cursor
    case gemini
    case grok
    case agy
    case opencode
    case pi
}

enum ConfigFormat: String, Codable, Sendable {
    case json
    case jsonc
    case toml
}

enum EntryDialect: String, Codable, Sendable {
    case standard
    case claude
    case opencode
}

enum Scope: String, CaseIterable, Codable, Sendable {
    case user
    case project

    static func normalized(for client: ClientName, requested: Scope?) -> Scope {
        client == .claude ? requested ?? .project : .user
    }
}

struct Roots: Equatable, Sendable {
    let home: URL
    let configHome: URL
    let stateHome: URL

    init(home: URL, configHome: URL, stateHome: URL) throws {
        guard home.path.hasPrefix("/"), configHome.path.hasPrefix("/"),
            stateHome.path.hasPrefix("/")
        else {
            throw SwapError.message("configuration roots must be absolute")
        }
        self.home = home.standardizedFileURL
        self.configHome = configHome.standardizedFileURL
        self.stateHome = stateHome.standardizedFileURL
    }

    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment) throws
        -> Roots
    {
        guard let rawHome = environment["HOME"], rawHome.hasPrefix("/") else {
            throw SwapError.message("HOME must name an absolute directory")
        }
        let home = URL(fileURLWithPath: rawHome)
        func absolute(_ name: String, fallback: URL) -> URL {
            guard let value = environment[name], value.hasPrefix("/") else { return fallback }
            return URL(fileURLWithPath: value)
        }
        return try Roots(
            home: home,
            configHome: absolute(
                "XDG_CONFIG_HOME", fallback: home.appending(path: ".config")),
            stateHome: absolute(
                "XDG_STATE_HOME", fallback: home.appending(path: ".local/state"))
        )
    }

    var swapDirectory: URL { stateHome.appending(path: "libtmux-mcp-dev/swap") }
    var stateDirectory: URL { swapDirectory.appending(path: "swift") }
    var stateFile: URL { stateDirectory.appending(path: "state.json") }
    var lockFile: URL { swapDirectory.appending(path: "state.lock") }
}

struct Client: Equatable, Sendable {
    let name: ClientName
    let binary: String
    let configPath: URL
    let format: ConfigFormat
    let container: String
    let dialect: EntryDialect
}

func knownClients(roots: Roots) -> [Client] {
    [
        Client(
            name: .claude,
            binary: "claude",
            configPath: roots.home.appending(path: ".claude.json"),
            format: .json,
            container: "mcpServers",
            dialect: .claude
        ),
        Client(
            name: .codex,
            binary: "codex",
            configPath: roots.home.appending(path: ".codex/config.toml"),
            format: .toml,
            container: "mcp_servers",
            dialect: .standard
        ),
        Client(
            name: .cursor,
            binary: "cursor-agent",
            configPath: roots.home.appending(path: ".cursor/mcp.json"),
            format: .json,
            container: "mcpServers",
            dialect: .standard
        ),
        Client(
            name: .gemini,
            binary: "gemini",
            configPath: roots.home.appending(path: ".gemini/settings.json"),
            format: .json,
            container: "mcpServers",
            dialect: .standard
        ),
        Client(
            name: .grok,
            binary: "grok",
            configPath: roots.home.appending(path: ".grok/config.toml"),
            format: .toml,
            container: "mcp_servers",
            dialect: .standard
        ),
        Client(
            name: .agy,
            binary: "agy",
            configPath: roots.home.appending(path: ".gemini/config/mcp_config.json"),
            format: .json,
            container: "mcpServers",
            dialect: .standard
        ),
        Client(
            name: .opencode,
            binary: "opencode",
            configPath: roots.configHome.appending(path: "opencode/opencode.jsonc"),
            format: .jsonc,
            container: "mcp",
            dialect: .opencode
        ),
        Client(
            name: .pi,
            binary: "pi",
            configPath: roots.home.appending(path: ".pi/agent/mcp.json"),
            format: .jsonc,
            container: "mcpServers",
            dialect: .standard
        ),
    ]
}

func selectClientNames(_ selectors: [String]) throws -> [ClientName] {
    guard !selectors.isEmpty else { return [] }
    var wanted = Set<ClientName>()
    for selector in selectors.flatMap({ $0.split(separator: ",").map(String.init) }) {
        let normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = normalized == "antigravity" ? "agy" : normalized
        guard let name = ClientName(rawValue: canonical) else {
            throw SwapError.message("unknown client \(normalized.debugDescription)")
        }
        wanted.insert(name)
    }
    return ClientName.allCases.filter(wanted.contains)
}

struct RepoMetadata: Equatable, Sendable {
    let package: URL
    let server: String
    let entry: String
}

enum SourceFlavor: String, CaseIterable, Sendable {
    case dev
    case debug
    case release
    case installed
}

struct ServerSpec: Equatable, Codable, Sendable {
    var command: String
    var arguments: [String]
    var environment: [String: String]

    func entry(for dialect: EntryDialect) -> [String: Any] {
        switch dialect {
        case .claude:
            return [
                "type": "stdio",
                "command": command,
                "args": arguments,
                "env": environment,
            ]
        case .opencode:
            var entry: [String: Any] = [
                "type": "local",
                "command": [command] + arguments,
            ]
            if !environment.isEmpty { entry["environment"] = environment }
            return entry
        case .standard:
            var entry: [String: Any] = ["command": command, "args": arguments]
            if !environment.isEmpty { entry["env"] = environment }
            return entry
        }
    }

    var pullRequest: (url: String, number: Int)? {
        guard command == "uvx" else { return nil }
        let expression = try? NSRegularExpression(
            pattern: #"^git\+(.+)@refs/pull/([1-9][0-9]*)/head$"#
        )
        for argument in arguments {
            let range = NSRange(argument.startIndex..., in: argument)
            guard let match = expression?.firstMatch(in: argument, range: range),
                let urlRange = Range(match.range(at: 1), in: argument),
                let numberRange = Range(match.range(at: 2), in: argument),
                let number = Int(argument[numberRange])
            else { continue }
            return (String(argument[urlRange]), number)
        }
        return nil
    }

    var localRepository: URL? {
        if URL(fileURLWithPath: command).lastPathComponent == "swift",
            let option = arguments.firstIndex(of: "--package-path"),
            arguments.indices.contains(option + 1)
        {
            return repositoryRoot(forPackage: URL(fileURLWithPath: arguments[option + 1]))
        }
        let components = URL(fileURLWithPath: command).standardizedFileURL.pathComponents
        guard let build = components.firstIndex(of: ".build") else { return nil }
        return repositoryRoot(
            forPackage: URL(
                fileURLWithPath: NSString.path(withComponents: Array(components[..<build])))
        )
    }
}

private func repositoryRoot(forPackage package: URL) -> URL {
    let standardized = package.standardizedFileURL
    return standardized.lastPathComponent == "swift"
        ? standardized.deletingLastPathComponent() : standardized
}

func resolveRepoMetadata(repo: URL) throws -> RepoMetadata {
    let root = repo.standardizedFileURL
    let rootManifest = root.appending(path: "Package.swift")
    let nested = root.appending(path: "swift")
    let package = FileManager.default.fileExists(atPath: rootManifest.path) ? root : nested
    let manifest = package.appending(path: "Package.swift")
    guard let data = FileManager.default.contents(atPath: manifest.path),
        let text = String(data: data, encoding: .utf8)
    else {
        throw SwapError.message("\(manifest.path) does not exist or is not UTF-8")
    }
    let expression = try NSRegularExpression(
        pattern: #"\.executable\(\s*name:\s*\"([^\"]+)\""#
    )
    let range = NSRange(text.startIndex..., in: text)
    guard let match = expression.firstMatch(in: text, range: range),
        let nameRange = Range(match.range(at: 1), in: text)
    else {
        throw SwapError.message("\(manifest.path) declares no executable product")
    }
    let entry = String(text[nameRange])
    let server = entry.hasSuffix("-mcp") ? String(entry.dropLast(4)) : entry
    return RepoMetadata(package: package, server: server, entry: entry)
}

func buildLocalSpec(
    repo: URL,
    entry: String,
    flavor: SourceFlavor = .dev,
    executableLookup: (String) -> URL? = executableOnPath
) throws -> ServerSpec {
    let metadata = try resolveRepoMetadata(repo: repo)
    switch flavor {
    case .dev:
        guard let executable = executableLookup("swift") else {
            throw SwapError.message("swift is not available on PATH")
        }
        let absolute =
            executable.path.hasPrefix("/")
            ? executable.standardizedFileURL
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: executable.path).standardizedFileURL
        return ServerSpec(
            command: absolute.path,
            arguments: ["run", "--package-path", metadata.package.path, entry],
            environment: [:]
        )
    case .installed:
        return ServerSpec(command: entry, arguments: [], environment: [:])
    case .debug, .release:
        guard entry != ".", entry != "..", !entry.isEmpty, !entry.contains("/") else {
            throw SwapError.message("a prebuilt entry must be a single executable name")
        }
        let binary = metadata.package.appending(path: ".build/\(flavor.rawValue)/\(entry)")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw SwapError.message("\(binary.path) does not exist; build it first")
        }
        return ServerSpec(
            command: binary.resolvingSymlinksInPath().path,
            arguments: [],
            environment: [:]
        )
    }
}

func buildPullRequestSpec(repoURL: String, number: Int, entry: String) throws -> ServerSpec {
    guard number > 0 else { throw SwapError.message("pull request number must be positive") }
    return ServerSpec(
        command: "uvx",
        arguments: ["--from", "git+\(repoURL)@refs/pull/\(number)/head", entry],
        environment: [:]
    )
}

func normalizeRemoteURL(_ raw: String) throws -> String {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("git+") { value.removeFirst(4) }
    if value.hasPrefix("ssh://") {
        value = "https://" + value.dropFirst(6)
    } else if !value.contains("://"), let colon = value.firstIndex(of: ":") {
        value = "https://" + value[..<colon] + "/" + value[value.index(after: colon)...]
    }
    guard let scheme = value.range(of: "://") else {
        throw SwapError.message("cannot normalize remote URL \(raw.debugDescription)")
    }
    let prefix = String(value[..<scheme.upperBound])
    let remainder = String(value[scheme.upperBound...])
    let pieces = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard pieces.count == 2 else {
        throw SwapError.message("cannot normalize remote URL \(raw.debugDescription)")
    }
    let authority = pieces[0].split(separator: "@").last.map(String.init) ?? ""
    var path = String(pieces[1])
    if path.hasSuffix(".git") { path.removeLast(4) }
    return "\(prefix)\(authority)/\(path)"
}

func executableOnPath(_ name: String) -> URL? {
    executableOnPath(name, environment: ProcessInfo.processInfo.environment)
}

func executableOnPath(_ name: String, environment: [String: String]) -> URL? {
    guard let path = environment["PATH"] else { return nil }
    for directory in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appending(path: name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}
