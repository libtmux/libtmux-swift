import Foundation
import Testing

@testable import McpSwapCore

@Test func cliHelpNamesEveryCommandAndMeaningfulUseOption() throws {
    let help = CLIParser.help(command: nil)
    for token in ["detect", "status", "use-local", "revert", "doctor"] {
        #expect(help.contains(token))
    }
    let useHelp = CLIParser.help(command: "use-local")
    for option in [
        "--repo", "--pr", "--flavour", "--no-preflight", "--server", "--entry",
        "--env", "--cli", "--scope", "--dry-run",
    ] {
        #expect(useHelp.contains(option))
    }
    #expect(useHelp.contains("dev"))
    #expect(useHelp.contains("debug"))
    #expect(useHelp.contains("release"))
    #expect(useHelp.contains("installed"))
}

@Test func cliParsesEveryUseSelectorAndCanonicalizesClients() throws {
    let invocation = try CLIParser.parse(
        [
            "use-local", "--repo", "/repo", "--pr", "42", "--flavour", "release",
            "--no-preflight", "--server", "tmux", "--entry", "libtmux-mcp", "--env",
            "KEEP=yes", "--env", "EMPTY=", "--cli", "cursor,claude", "--cli",
            "antigravity", "--scope", "user", "--dry-run",
        ])
    guard case .use(let request) = invocation else {
        Issue.record("expected use-local invocation")
        return
    }
    #expect(request.repo.path == "/repo")
    #expect(request.pullRequest == 42)
    #expect(request.flavor == .release)
    #expect(request.server == "tmux")
    #expect(request.entry == "libtmux-mcp")
    #expect(request.environment == ["KEEP": "yes", "EMPTY": ""])
    #expect(request.clients == [.claude, .cursor, .agy])
    #expect(request.scope == .user)
    #expect(request.dryRun)
    #expect(request.noPreflight)
}

@Test func cliRejectsUnknownMisplacedAndMalformedOptions() {
    for arguments in [
        ["detect", "--dry-run"],
        ["detect", "--cli", "cursor"],
        ["status", "--env", "A=B"],
        ["revert", "--repo", "/repo"],
        ["doctor", "--scope", "user"],
        ["use-local", "--env", "NOEQUALS"],
        ["use-local", "--env", "LIBTMUX_SAFETY=readonly"],
        ["use-local", "--pr", "0"],
        ["use-local", "--flavour", "fast"],
        ["use-local", "--cli", "unknown"],
        ["use-local", "--repo"],
        ["unknown"],
    ] {
        #expect(throws: SwapError.self) { try CLIParser.parse(arguments) }
    }
}

@Test func cliRetiredSafetyErrorNamesItsReplacement() {
    do {
        _ = try CLIParser.parse(["use-local", "--env", "LIBTMUX_SAFETY=readonly"])
        Issue.record("retired safety setting was accepted")
    } catch let error as SwapError {
        #expect(error.description.contains("LIBTMUX_SAFETY has been removed"))
        #expect(error.description.contains("LIBTMUX_TOOLSETS"))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func cliParsesStatusRevertDoctorAndScopedHelp() throws {
    guard
        case .status(let status) = try CLIParser.parse(
            [
                "status", "--repo", "/repo", "--server", "tmux", "--cli", "claude", "--scope",
                "project",
            ])
    else {
        Issue.record("expected status")
        return
    }
    #expect(status.clients == [.claude])
    #expect(status.scope == .project)

    guard
        case .revert(let revert) = try CLIParser.parse(
            ["revert", "--cli", "claude", "--scope", "user", "--dry-run"])
    else {
        Issue.record("expected revert")
        return
    }
    #expect(revert.clients == [.claude])
    #expect(revert.scope == .user)
    #expect(revert.dryRun)

    guard
        case .doctor(let doctor) = try CLIParser.parse(
            ["doctor", "--repo", "/repo", "--server", "tmux"])
    else {
        Issue.record("expected doctor")
        return
    }
    #expect(doctor.server == "tmux")

    #expect(try CLIParser.parse(["status", "--help"]) == .help("status"))
    guard case .use(let defaults) = try CLIParser.parse(["use-local"]) else {
        Issue.record("expected default use-local")
        return
    }
    #expect(defaults.clients.isEmpty)
}

@Test func statusRendersOnlyTheRequestedClaudeScope() throws {
    try withCLIFixture { root, repo, environment in
        let config = root.appending(path: "home/.claude.json")
        let document: [String: Any] = [
            "mcpServers": [
                "libtmux": ["type": "stdio", "command": "user-server", "args": []]
            ],
            "projects": [
                repo.path: [
                    "mcpServers": [
                        "libtmux": [
                            "type": "stdio", "command": "project-server", "args": [],
                        ]
                    ]
                ]
            ],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: config)

        for (scope, expected, excluded) in [
            ("user", "user-server", "project-server"),
            ("project", "project-server", "user-server"),
        ] {
            var output: [String] = []
            let status = CommandRunner.run(
                arguments: [
                    "status", "--repo", repo.path, "--server", "libtmux", "--cli", "claude",
                    "--scope", scope,
                ],
                environment: environment,
                stdout: { output.append($0) },
                stderr: { output.append("error: \($0)") })

            #expect(status == 0)
            #expect(output.count == 1)
            #expect(output[0].contains("[claude:\(scope)]"))
            #expect(output[0].contains(expected))
            #expect(!output[0].contains(excluded))
        }

        var output: [String] = []
        #expect(
            CommandRunner.run(
                arguments: [
                    "status", "--repo", repo.path, "--server", "libtmux", "--cli", "claude",
                ],
                environment: environment,
                stdout: { output.append($0) },
                stderr: { output.append("error: \($0)") }) == 0)
        #expect(output.count == 2)
        #expect(output.contains { $0.contains("[claude:user]") && $0.contains("user-server") })
        #expect(
            output.contains {
                $0.contains("[claude:project]") && $0.contains("project-server")
            })
    }
}

@Test func detectExplainsThatPiNeedsItsAdapter() throws {
    try withCLIFixture { root, _, environment in
        let piConfig = root.appending(path: "home/.pi/agent/mcp.json")
        try FileManager.default.createDirectory(
            at: piConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: piConfig)
        var output: [String] = []

        #expect(
            CommandRunner.run(
                arguments: ["detect"], environment: environment,
                stdout: { output.append($0) }, stderr: { _ in }) == 0)
        let pi = try #require(output.first { $0.contains("] pi") })
        #expect(pi.contains("pi-mcp-adapter"))
        #expect(pi.contains("no built-in MCP client"))
    }
}

@Test func doctorFindsTheRepoRegisteredUnderAnotherServerName() throws {
    try withCLIFixture { root, repo, environment in
        let config = root.appending(path: "home/.claude.json")
        let document: [String: Any] = [
            "mcpServers": [
                "tmux": [
                    "type": "stdio",
                    "command": "/usr/bin/swift",
                    "args": ["run", "--package-path", repo.path, "libtmux-mcp"],
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: config)
        var output: [String] = []

        #expect(
            CommandRunner.run(
                arguments: ["doctor", "--repo", repo.path], environment: environment,
                stdout: { output.append($0) }, stderr: { output.append("error: \($0)") }) == 0)
        #expect(output.contains { $0.contains("[claude:user] tmux = local: this repo") })
        #expect(output.contains { $0.contains("server name mismatch") })
        #expect(output.contains { $0.contains("--server tmux") })
    }
}

private func withCLIFixture(
    _ body: (URL, URL, [String: String]) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "mcp-swap-cli-\(UUID().uuidString)")
    let home = root.appending(path: "home")
    let repo = root.appending(path: "repo")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(
        name: "libtmux",
        products: [.executable(name: "libtmux-mcp", targets: ["libtmux-mcp"])]
    )
    """.write(
        to: repo.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
    try body(
        root,
        repo,
        [
            "HOME": home.path,
            "XDG_CONFIG_HOME": root.appending(path: "config").path,
            "XDG_STATE_HOME": root.appending(path: "state").path,
            "PATH": "",
        ])
}
