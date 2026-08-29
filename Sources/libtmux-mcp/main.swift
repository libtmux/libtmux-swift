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
/// This file is only the part that needs a process: reading a pipe, writing
/// one, and keeping the two from interleaving.

private func note(_ message: String) {
    FileHandle.standardError.write(Data("libtmux-mcp: \(message)\n".utf8))
}

private let inputChunkBytes = 64 * 1_024
private let queuedRequestLines = 8

private func emitInput(
    _ event: BoundedLineFramer.Event,
    to continuation: AsyncStream<String>.Continuation
) -> Bool {
    switch event {
    case let .line(line):
        switch continuation.yield(line) {
        case .enqueued: return true
        case .dropped:
            note("stdin queue exceeded \(queuedRequestLines) request lines; closing input")
            continuation.finish()
            return false
        case .terminated: return false
        @unknown default: return false
        }
    case .oversized:
        note(
            "discarded a request above "
                + "\(MCPRequestHandler.maximumRequestBytes) bytes"
        )
        return true
    case .invalidUTF8:
        note("discarded a request that was not UTF-8")
        return true
    }
}

/// Lines from standard input, read on a thread of its own.
///
/// `readLine` blocks until a line arrives. On a cooperative thread that would
/// stall whichever task was scheduled there — including the tool calls this
/// server exists to run concurrently — so the one blocking call in the process
/// gets a thread that is allowed to block.
private func standardInputLines() -> AsyncStream<String> {
    AsyncStream(bufferingPolicy: .bufferingOldest(queuedRequestLines)) { continuation in
        let reader = Thread {
            var framer = BoundedLineFramer(
                maximumBytes: MCPRequestHandler.maximumRequestBytes
            )
            while true {
                let chunk = FileHandle.standardInput.readData(ofLength: inputChunkBytes)
                if chunk.isEmpty {
                    for event in framer.finish() {
                        guard emitInput(event, to: continuation) else { return }
                    }
                    continuation.finish()
                    return
                }
                for event in framer.append(chunk) {
                    guard emitInput(event, to: continuation) else { return }
                }
            }
        }
        reader.name = "libtmux-mcp.stdin"
        reader.start()
    }
}

/// Serialises writes to standard output.
///
/// Answers are produced concurrently and a response is one line; two tasks
/// writing at once would interleave halves of two messages and desynchronise
/// the stream for good.
private actor OutputWriter {
    func write(_ line: String) {
        FileHandle.standardOutput.write(Data("\(line)\n".utf8))
    }
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
note(
    "serving \(configuration.endpointSummary) through \(configuration.tmuxExecutable) "
        + "at the \(configuration.tier.rawValue) tier"
)

private let writer = OutputWriter()
await MCPService(handler: MCPRequestHandler(tools: tools)).serve(
    standardInputLines(),
    write: { await writer.write($0) }
)
