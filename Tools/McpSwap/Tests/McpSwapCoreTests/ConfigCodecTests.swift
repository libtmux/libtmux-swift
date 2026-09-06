import Foundation
import Testing

@testable import McpSwapCore

@Test func strictJSONRoundTripsServerMutationWithoutTouchingSiblingValues() throws {
    let client = fixtureClient(.cursor)
    let original = Data(
        """
        {
          "model": "Fable 5 · Most capable…",
          "mcpServers": {
            "keep": {"command": "echo", "args": ["🙂"]},
            "libtmux": {"command": "uvx", "args": ["libtmux-mcp==old"], "env": {"KEEP": "yes"}}
          }
        }
        """.utf8
    )
    var replacement = ServerSpec(
        command: "/repo/.build/debug/libtmux-mcp", arguments: [], environment: [:])
    let current = try ConfigCodec.readServer(
        client: client,
        bytes: original,
        server: "libtmux",
        repo: URL(fileURLWithPath: "/repo"),
        scope: .user
    )
    replacement.environment = current?.environment ?? [:]

    let result = try ConfigCodec.settingServer(
        client: client,
        bytes: original,
        server: "libtmux",
        spec: replacement,
        repo: URL(fileURLWithPath: "/repo"),
        scope: .user
    )

    #expect(result.action == .replaced)
    #expect(String(decoding: result.bytes, as: UTF8.self).contains("Fable 5 · Most capable…"))
    #expect(String(decoding: result.bytes, as: UTF8.self).contains("🙂"))
    #expect(
        try ConfigCodec.readServer(
            client: client,
            bytes: result.bytes,
            server: "libtmux",
            repo: URL(fileURLWithPath: "/repo"),
            scope: .user
        ) == replacement
    )
}

@Test func JSONRejectsTrailingTokensAndMalformedUTF8() {
    let client = fixtureClient(.cursor)
    for bytes in [
        Data(#"{"mcpServers": {}} true"#.utf8), Data([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x31, 0x7d]),
    ] {
        #expect(throws: SwapError.self) {
            try ConfigCodec.readServer(
                client: client,
                bytes: bytes,
                server: "libtmux",
                repo: URL(fileURLWithPath: "/repo"),
                scope: .user
            )
        }
    }
}

@Test func JSONAndJSONCRejectDuplicateObjectKeys() {
    for (client, bytes) in [
        (fixtureClient(.cursor), Data(#"{"mcpServers":{},"mcpServers":{}}"#.utf8)),
        (fixtureClient(.opencode), Data(#"{"mcp":{},/* keep */"mcp":{},}"#.utf8)),
    ] {
        #expect(throws: SwapError.self) {
            try ConfigCodec.readServer(
                client: client,
                bytes: bytes,
                server: "libtmux",
                repo: URL(fileURLWithPath: "/repo"),
                scope: .user
            )
        }
    }
}

@Test func JSONCPreservesCommentsTrailingCommaAndEntryRationale() throws {
    let client = fixtureClient(.opencode)
    let original = Data(
        """
        {
          // header stays
          "mcp": {
            "libtmux": {
              "type": "local",
              // this pin is deliberate
              "command": ["uvx", "libtmux-mcp==old"],
              "environment": {"KEEP": "yes"},
            },
          },
        }
        """.utf8
    )
    let spec = ServerSpec(
        command: "/repo/.build/debug/libtmux-mcp",
        arguments: [],
        environment: ["KEEP": "yes"]
    )

    let result = try ConfigCodec.settingServer(
        client: client,
        bytes: original,
        server: "libtmux",
        spec: spec,
        repo: URL(fileURLWithPath: "/repo"),
        scope: .user
    )
    let text = String(decoding: result.bytes, as: UTF8.self)

    #expect(text.contains("// header stays"))
    #expect(text.contains("// this pin is deliberate"))
    #expect(text.contains("\"environment\": {\"KEEP\": \"yes\"}"))
    #expect(
        try ConfigCodec.readServer(
            client: client,
            bytes: result.bytes,
            server: "libtmux",
            repo: URL(fileURLWithPath: "/repo"),
            scope: .user
        ) == spec
    )
}

@Test func JSONCRejectsTrailingTokensAndMalformedUTF8() {
    let client = fixtureClient(.pi)
    for bytes in [
        Data(#"{"mcpServers": {}} false"#.utf8),
        Data("/* unterminated".utf8),
        Data(#"{"mcpServers": {}} /* unterminated"#.utf8),
        Data([0x7b, 0x2f, 0x2f, 0xff, 0x0a, 0x7d]),
    ] {
        #expect(throws: SwapError.self) {
            try ConfigCodec.readServer(
                client: client,
                bytes: bytes,
                server: "libtmux",
                repo: URL(fileURLWithPath: "/repo"),
                scope: .user
            )
        }
    }
}

@Test func TOMLPreservesCommentsAndValidatesTheWholeDocument() throws {
    let client = fixtureClient(.codex)
    let original = Data(
        """
        # top-level rationale
        title = "café"

        [mcp_servers.libtmux] # server-table rationale
        # pinned until the branch is checked
        command = "uvx"
        args = ["libtmux-mcp==old"]

        [mcp_servers.libtmux.env]
        KEEP = "yes"

        [[other.array]] # sibling-table rationale
        when = 1979-05-27T07:32:00Z
        inline = { answer = 42, labels = ["a", "b"] }
        matrix = [
          [1, 2],
          [3, 4],
        ]
        """.utf8
    )
    let spec = ServerSpec(
        command: "/repo/.build/release/libtmux-mcp",
        arguments: [],
        environment: ["KEEP": "yes"]
    )

    let result = try ConfigCodec.settingServer(
        client: client,
        bytes: original,
        server: "libtmux",
        spec: spec,
        repo: URL(fileURLWithPath: "/repo"),
        scope: .user
    )
    let text = String(decoding: result.bytes, as: UTF8.self)

    #expect(text.contains("# top-level rationale"))
    #expect(text.contains("# pinned until the branch is checked"))
    #expect(text.contains("# server-table rationale"))
    #expect(text.contains("[[other.array]]"))
    #expect(text.contains("# sibling-table rationale"))
    #expect(text.contains("[3, 4]"))
    #expect(text.contains("when = 1979-05-27T07:32:00Z"))
    #expect(
        try ConfigCodec.readServer(
            client: client,
            bytes: result.bytes,
            server: "libtmux",
            repo: URL(fileURLWithPath: "/repo"),
            scope: .user
        ) == spec
    )

    let malformedElsewhere = Data(
        """
        [mcp_servers.libtmux]
        command = "uvx"
        broken = [1, 2
        """.utf8
    )
    #expect(throws: (any Error).self) {
        try ConfigCodec.settingServer(
            client: client,
            bytes: malformedElsewhere,
            server: "libtmux",
            spec: spec,
            repo: URL(fileURLWithPath: "/repo"),
            scope: .user
        )
    }
}

@Test func TOMLRejectsMalformedUTF8() {
    #expect(throws: SwapError.self) {
        try ConfigCodec.readServer(
            client: fixtureClient(.grok),
            bytes: Data([0x5b, 0x78, 0x5d, 0x0a, 0xff]),
            server: "libtmux",
            repo: URL(fileURLWithPath: "/repo"),
            scope: .user
        )
    }
}

@Test func ClaudeScopesRemainSeparateAndRejectWrongShapes() throws {
    let client = fixtureClient(.claude)
    let repo = URL(fileURLWithPath: "/repo")
    let user = ServerSpec(command: "user", arguments: [], environment: [:])
    let project = ServerSpec(command: "project", arguments: [], environment: [:])
    var bytes = Data(#"{"mcpServers": {}}"#.utf8)

    bytes = try ConfigCodec.settingServer(
        client: client, bytes: bytes, server: "tmux", spec: user, repo: repo, scope: .user
    ).bytes
    bytes = try ConfigCodec.settingServer(
        client: client,
        bytes: bytes,
        server: "tmux",
        spec: project,
        repo: repo,
        scope: .project
    ).bytes

    #expect(
        try ConfigCodec.readServer(
            client: client, bytes: bytes, server: "tmux", repo: repo, scope: .user
        ) == user
    )
    #expect(
        try ConfigCodec.readServer(
            client: client, bytes: bytes, server: "tmux", repo: repo, scope: .project
        ) == project
    )
    #expect(throws: SwapError.self) {
        try ConfigCodec.settingServer(
            client: client,
            bytes: Data(#"{"projects": []}"#.utf8),
            server: "tmux",
            spec: project,
            repo: repo,
            scope: .project
        )
    }
}

private func fixtureClient(_ name: ClientName) -> Client {
    let root = URL(fileURLWithPath: "/tmp/mcp-swap-codec")
    let roots = try! Roots(
        home: root, configHome: root.appending(path: "cfg"),
        stateHome: root.appending(path: "state"))
    return knownClients(roots: roots).first { $0.name == name }!
}
