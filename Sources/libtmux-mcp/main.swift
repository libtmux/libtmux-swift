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

let environment = ProcessInfo.processInfo.environment
let socketName = environment["LIBTMUX_SOCKET"] ?? "default"
let requestedExecutable = environment["LIBTMUX_TMUX_BIN"] ?? "tmux"

let server: Server
do {
    server = try Server(socketName: socketName, tmuxExecutable: requestedExecutable)
} catch {
    note("cannot address a tmux server: \(error)")
    exit(1)
}
let handler = MCPRequestHandler(tools: TmuxTools(server: server))
note("serving tmux socket \(socketName) through \(requestedExecutable)")

while let line = readLine(strippingNewline: true) {
    guard let response = await handler.respond(to: line) else { continue }
    FileHandle.standardOutput.write(Data(response.utf8))
    FileHandle.standardOutput.write(Data("\n".utf8))
}
