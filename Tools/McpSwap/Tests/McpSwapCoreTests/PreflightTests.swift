import Foundation
import Testing

@testable import McpSwapCore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

@Test func preflightCompletesInitializeAndPassesTheFinalEnvironment() throws {
    try withPreflightFixture { root in
        let server = root.appending(path: "server.sh")
        try script(
            """
            #!/bin/sh
            IFS= read -r request
            test "$MCP_SWAP_PROBE" = expected || exit 7
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}'
            """,
            at: server
        )
        let spec = ServerSpec(
            command: server.path,
            arguments: [],
            environment: ["MCP_SWAP_PROBE": "expected"]
        )

        try preflight(spec, timeout: 3)
    }
}

@Test func preflightResolvesAnInstalledCommandFromTheFinalEnvironmentPath() throws {
    try withPreflightFixture { root in
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let server = bin.appending(path: "fixture-mcp")
        try script(
            """
            #!/bin/sh
            IFS= read -r request
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}'
            """,
            at: server)

        try preflight(
            ServerSpec(command: "fixture-mcp", arguments: [], environment: [:]),
            timeout: 3,
            baseEnvironment: ["PATH": bin.path])
    }
}

@Test func preflightAcceptsALiveServerThenTerminatesAndReapsItsProcessGroup() throws {
    try withPreflightFixture { root in
        let server = root.appending(path: "server.sh")
        let parentPID = root.appending(path: "parent.pid")
        let childPID = root.appending(path: "child.pid")
        try script(
            """
            #!/bin/sh
            printf '%s' "$$" > "$PARENT_PID_FILE"
            sleep 30 &
            printf '%s' "$!" > "$CHILD_PID_FILE"
            IFS= read -r request
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}'
            sleep 30
            """,
            at: server
        )
        let start = Date()

        try preflight(
            ServerSpec(
                command: server.path,
                arguments: [],
                environment: [
                    "PARENT_PID_FILE": parentPID.path,
                    "CHILD_PID_FILE": childPID.path,
                ]),
            timeout: 3)

        #expect(Date().timeIntervalSince(start) < 2)
        let parent = try fixturePID(parentPID)
        let child = try fixturePID(childPID)
        #expect(waitUntilGone(parent))
        #expect(waitUntilGone(child))
    }
}

@Test func preflightReportsStderrWhenTheServerDoesNotAnswer() throws {
    try withPreflightFixture { root in
        let server = root.appending(path: "server.sh")
        try script(
            """
            #!/bin/sh
            printf '%s\n' first second 'could not initialize' >&2
            exit 1
            """,
            at: server
        )

        do {
            try preflight(
                ServerSpec(command: server.path, arguments: [], environment: [:]), timeout: 3)
            Issue.record("preflight accepted a server without initialize")
        } catch let error as SwapError {
            #expect(error.description.contains("could not initialize"))
        }
    }
}

@Test func preflightRequiresJSONRPCAndANonemptyProtocolVersion() throws {
    let invalidResponses = [
        #"{"id":1,"result":{"protocolVersion":"2025-06-18"}}"#,
        #"{"jsonrpc":"1.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":""}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":[]}"#,
        #"{"jsonrpc":"2.0","id":9,"id":1,"result":{"protocolVersion":"2025-06-18"}}"#,
    ]
    try withPreflightFixture { root in
        for (index, response) in invalidResponses.enumerated() {
            let server = root.appending(path: "invalid-\(index).sh")
            try script(
                """
                #!/bin/sh
                IFS= read -r request
                printf '%s\n' '\(response)'
                """,
                at: server)
            #expect(throws: SwapError.self) {
                try preflight(
                    ServerSpec(command: server.path, arguments: [], environment: [:]), timeout: 3)
            }
        }
    }
}

@Test func preflightRejectsMissingCommandsAndTimeouts() throws {
    #expect(throws: SwapError.self) {
        try preflight(
            ServerSpec(command: "/no/such/mcp-swap-server", arguments: [], environment: [:]),
            timeout: 1
        )
    }
    try withPreflightFixture { root in
        let server = root.appending(path: "server.sh")
        try script("#!/bin/sh\nsleep 10\n", at: server)
        let start = Date()
        #expect(throws: SwapError.self) {
            try preflight(
                ServerSpec(command: server.path, arguments: [], environment: [:]), timeout: 0.1)
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

@Test func preflightBoundsOutputAndKillsTheProducingProcessTree() throws {
    try withPreflightFixture { root in
        for stream in ["stdout", "stderr"] {
            let server = root.appending(path: "\(stream)-server.sh")
            let childPID = root.appending(path: "\(stream)-child.pid")
            try script(
                """
                #!/bin/sh
                sleep 30 &
                printf '%s' "$!" > "$CHILD_PID_FILE"
                if [ "$OUTPUT_STREAM" = stderr ]; then
                    yes x | head -c 8192 >&2
                else
                    yes x | head -c 8192
                fi
                sleep 30
                """,
                at: server
            )

            do {
                try preflight(
                    ServerSpec(
                        command: server.path,
                        arguments: [],
                        environment: [
                            "CHILD_PID_FILE": childPID.path,
                            "OUTPUT_STREAM": stream,
                        ]),
                    timeout: 3,
                    maximumOutputBytes: 1024)
                Issue.record("preflight accepted unbounded \(stream)")
            } catch let error as SwapError {
                #expect(error.description.contains("output exceeded 1024 bytes"))
            }
            #expect(waitUntilGone(try fixturePID(childPID)))
        }
    }
}

@Test func preflightAppliesOneCombinedOutputLimit() throws {
    try withPreflightFixture { root in
        let server = root.appending(path: "server.sh")
        try script(
            """
            #!/bin/sh
            head -c 600 /dev/zero | tr '\\000' x
            head -c 600 /dev/zero | tr '\\000' y >&2
            sleep 30
            """,
            at: server)

        do {
            try preflight(
                ServerSpec(command: server.path, arguments: [], environment: [:]),
                timeout: 1,
                maximumOutputBytes: 1024)
            Issue.record("preflight accepted combined output over the limit")
        } catch let error as SwapError {
            #expect(error.description.contains("output exceeded 1024 bytes"))
        }
    }
}

private func script(_ body: String, at url: URL) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: UInt16(0o700))], ofItemAtPath: url.path)
}

private func withPreflightFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "mcp-swap-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func fixturePID(_ url: URL) throws -> Int32 {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
}

private func waitUntilGone(_ pid: Int32) -> Bool {
    for _ in 0..<100 {
        if kill(pid, 0) != 0 { return true }
        usleep(10_000)
    }
    return kill(pid, 0) != 0
}
