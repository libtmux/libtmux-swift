// The examples in the transport section of the README.

import LibTmux

/// Stands in for tmux, answering every command with one canned reply.
public struct StubTransport: ProcessTransport {
    public let reply: TmuxReply
    public init(reply: TmuxReply) {
        self.reply = reply
    }

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        reply
    }
}

public func withoutATmuxOnTheMachine() async throws -> [String] {
    // One session row: id, name, windows, attached, created, then the daemon
    // identity every value carries. U+241E separates the fields, as the
    // library's own projections ask tmux for them.
    let row = ["$0", "work", "2", "0", "1750000000", "/tmp/libtmux-swift-dev/none", "4242", "17"]
    let transport = StubTransport(
        reply: TmuxReply(
            standardOutput: Array((row.joined(separator: "\u{241E}") + "\n").utf8),
            standardError: [],
            exitCode: 0
        )
    )
    let server = try Server(socketPath: "/tmp/libtmux-swift-dev/none", transport: transport)
    return try await server.sessions().map(\.name)
}
