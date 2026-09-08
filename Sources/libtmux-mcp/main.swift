import Foundation
import LibTmux
import LibTmuxMCP

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

_ = signal(SIGPIPE, SIG_IGN)

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

private func readStandardInput(into buffer: inout [UInt8]) -> Int {
    buffer.withUnsafeMutableBytes { bytes in
        #if canImport(Darwin)
            Darwin.read(STDIN_FILENO, bytes.baseAddress, bytes.count)
        #else
            Glibc.read(STDIN_FILENO, bytes.baseAddress, bytes.count)
        #endif
    }
}

private func emitInput(
    _ event: BoundedLineFramer.Event,
    to handoff: BoundedLineHandoff
) -> Bool {
    switch event {
    case .line:
        break
    case .oversized:
        note(
            "refused a request above "
                + "\(MCPRequestHandler.maximumRequestBytes) bytes"
        )
    case .invalidUTF8:
        note("refused a request that was not UTF-8")
    }
    return handoff.submit(MCPInput.requestLine(for: event))
}

/// Lines from standard input, read on a thread of its own.
///
/// `readLine` blocks until a line arrives. On a cooperative thread that would
/// stall whichever task was scheduled there — including the tool calls this
/// server exists to run concurrently — so the one blocking call in the process
/// gets a thread that is allowed to block.
private func standardInputLines() -> BoundedLineHandoff {
    let handoff = BoundedLineHandoff(capacity: queuedRequestLines)
    let reader = Thread {
        var framer = BoundedLineFramer(
            maximumBytes: MCPRequestHandler.maximumRequestBytes
        )
        var buffer = [UInt8](repeating: 0, count: inputChunkBytes)
        while true {
            let count = readStandardInput(into: &buffer)
            if count == 0 {
                for event in framer.finish() {
                    guard emitInput(event, to: handoff) else { return }
                }
                handoff.finish()
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                note("cannot read standard input: \(String(cString: strerror(errno)))")
                handoff.finish()
                return
            }
            let chunk = Data(buffer[..<count])
            for event in framer.append(chunk) {
                guard emitInput(event, to: handoff) else { return }
            }
        }
    }
    reader.name = "libtmux-mcp.stdin"
    reader.start()
    return handoff
}

let configuration = ServerConfiguration(
    environment: ProcessInfo.processInfo.environment
)
for warning in configuration.warnings { note(warning) }
if !configuration.errors.isEmpty {
    for error in configuration.errors { note(error) }
    exit(2)
}

let pin: StartupPin
do {
    pin = try await configuration.pinForStartup()
} catch {
    note("cannot pin tmux server provenance: \(error)")
    exit(1)
}

let tools = TmuxTools(
    server: pin.server,
    authority: pin.authority,
    waitCeiling: configuration.waitCeiling,
    provenance: pin.provenance
)
note(
    "serving \(configuration.endpointSummary) through \(configuration.tmuxExecutable) "
        + "with \(tools.authority.summary)"
)

private let writer: NonblockingLineWriter
do {
    writer = try NonblockingLineWriter(fileDescriptor: STDOUT_FILENO)
} catch {
    note("cannot configure standard output: \(error)")
    await pin.cleanupOwnedLaunch()
    exit(1)
}

await MCPService(handler: MCPRequestHandler(tools: tools)).serveUntilWriteFails(
    standardInputLines(),
    write: { line in
        switch await writer.write(line) {
        case .written:
            return true
        case .closed, .cancelled:
            return false
        case let .failed(code):
            note("cannot write standard output: \(String(cString: strerror(code)))")
            return false
        }
    }
)
await pin.cleanupOwnedLaunch()
