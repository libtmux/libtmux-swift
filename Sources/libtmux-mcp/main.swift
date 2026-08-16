import Foundation
import LibTmux
import LibTmuxMCP

/// An MCP server over stdio.
///
/// Speaks JSON-RPC 2.0 on stdin and stdout, one message per line. Anything the
/// server wants to say to a human goes to stderr, because stdout is the
/// protocol and a stray `print` there corrupts the stream.
///
/// What the protocol decides lives in `LibTmuxMCP`, where a test can reach it.
/// This file is only the part that needs a process.

private func note(_ message: String) {
    FileHandle.standardError.write(Data("libtmux-mcp: \(message)\n".utf8))
}

let configuration = ServerConfiguration(
    environment: ProcessInfo.processInfo.environment
)
for warning in configuration.warnings { note(warning) }

let server: Server
do {
    server = try configuration.makeServer()
} catch {
    note("cannot address a tmux server: \(error)")
    exit(1)
}

let tools = TmuxTools(
    server: server,
    tier: configuration.tier,
    waitCeiling: configuration.waitCeiling
)
let handler = MCPRequestHandler(tools: tools)
note(
    "serving \(configuration.endpointSummary) through \(configuration.tmuxExecutable) "
        + "at the \(configuration.tier.rawValue) tier"
)

while let line = readLine(strippingNewline: true) {
    guard let response = await handler.respond(to: line) else { continue }
    FileHandle.standardOutput.write(Data(response.utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
}
