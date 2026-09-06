import CMcpSwap
import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

private let initializeFrame = Data(
    """
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp-swap-preflight","version":"1"}}}

    """.utf8
)

func preflight(
    _ spec: ServerSpec,
    timeout: TimeInterval = 300,
    maximumOutputBytes: Int = 1024 * 1024,
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    guard timeout > 0 else { throw SwapError.message("preflight timeout must be positive") }
    guard maximumOutputBytes > 0 else {
        throw SwapError.message("preflight output limit must be positive")
    }
    let arguments = try nulList(spec.arguments, label: "argument")
    let finalEnvironment = baseEnvironment.merging(spec.environment) { _, requested in requested }
    let command =
        spec.command.contains("/")
        ? spec.command
        : executableOnPath(spec.command, environment: finalEnvironment)?.path ?? spec.command
    let environment = try nulList(
        finalEnvironment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
        label: "environment")
    var child = mcp_swap_child()
    let spawnResult = command.withCString { command in
        arguments.withUnsafeBytes { rawArguments in
            environment.withUnsafeBytes { rawEnvironment in
                mcp_swap_spawn(
                    command,
                    rawArguments.baseAddress?.assumingMemoryBound(to: CChar.self),
                    UInt64(rawArguments.count),
                    rawEnvironment.baseAddress?.assumingMemoryBound(to: CChar.self),
                    UInt64(rawEnvironment.count),
                    &child)
            }
        }
    }
    guard spawnResult == 0 else {
        throw SwapError.message("could not launch \(spec.command): \(posixDescription())")
    }

    var input = child.input
    var output = child.output
    var errorOutput = child.error
    var reaped = false
    defer {
        if input >= 0 { _ = close(input) }
        if output >= 0 { _ = close(output) }
        if errorOutput >= 0 { _ = close(errorOutput) }
        terminateProcessGroup(child.pid, reaped: &reaped)
    }
    let writeResult = initializeFrame.withUnsafeBytes { bytes in
        mcp_swap_write_all_no_sigpipe(input, bytes.baseAddress, UInt64(bytes.count))
    }
    var transportFailure: String?
    if writeResult != 0 {
        transportFailure = "could not write MCP initialize request: \(posixDescription())"
    }
    if close(input) != 0, transportFailure == nil {
        transportFailure = "could not close MCP initialize request: \(posixDescription())"
    }
    input = -1

    let deadline = Date().addingTimeInterval(timeout)
    var stdout = Data()
    var stderr = Data()
    var pending = Data()
    var responseFailure: String?
    while Date() < deadline {
        var ready: Int32 = 0
        let remaining = max(1, min(50, Int(deadline.timeIntervalSinceNow * 1000)))
        guard mcp_swap_wait_readable(output, errorOutput, Int32(remaining), &ready) >= 0 else {
            throw SwapError.message("could not poll MCP server: \(posixDescription())")
        }
        if ready & 1 != 0, output >= 0 {
            let chunk = try readChunk(output, label: "MCP preflight stdout")
            if chunk.isEmpty {
                _ = close(output)
                output = -1
            } else {
                stdout.append(chunk)
                pending.append(chunk)
                guard stdout.count + stderr.count <= maximumOutputBytes else {
                    throw SwapError.message(
                        "MCP preflight output exceeded \(maximumOutputBytes) bytes")
                }
                while let newline = pending.firstIndex(of: 0x0a) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    if let outcome = try initializeOutcome(Data(line)) {
                        switch outcome {
                        case .accepted: return
                        case .rejected(let message): responseFailure = message
                        }
                    }
                }
            }
        }
        if ready & 2 != 0, errorOutput >= 0 {
            let chunk = try readChunk(errorOutput, label: "MCP preflight stderr")
            if chunk.isEmpty {
                _ = close(errorOutput)
                errorOutput = -1
            } else {
                stderr.append(chunk)
                guard stdout.count + stderr.count <= maximumOutputBytes else {
                    throw SwapError.message(
                        "MCP preflight output exceeded \(maximumOutputBytes) bytes")
                }
            }
        }
        if !reaped {
            var status: Int32 = 0
            let waited = mcp_swap_wait_child(child.pid, 1, &status)
            guard waited >= 0 else {
                throw SwapError.message("could not reap MCP server: \(posixDescription())")
            }
            reaped = waited == 1
        }
        if reaped, output < 0, errorOutput < 0 {
            if !pending.isEmpty, let outcome = try initializeOutcome(pending) {
                if case .accepted = outcome { return }
                if case .rejected(let message) = outcome { responseFailure = message }
            }
            throw preflightFailure(
                responseFailure: responseFailure,
                transportFailure: transportFailure,
                stderr: stderr)
        }
    }
    if let transportFailure {
        throw preflightFailure(
            responseFailure: responseFailure,
            transportFailure: transportFailure,
            stderr: stderr)
    }
    throw SwapError.message(String(format: "no MCP response within %.1fs", timeout))
}

private enum InitializeOutcome {
    case accepted
    case rejected(String)
}

private func initializeOutcome(_ line: Data) throws -> InitializeOutcome? {
    guard !line.isEmpty else { return nil }
    let text = try strictUTF8(line, label: "MCP preflight stdout")
    let value: Any
    do { value = try JSONSerialization.jsonObject(with: line) } catch { return nil }
    try rejectDuplicateJSONKeys(text)
    guard let message = value as? [String: Any],
        (message["id"] as? NSNumber)?.intValue == 1
    else { return nil }
    guard message["jsonrpc"] as? String == "2.0" else {
        return .rejected("initialize response has an invalid jsonrpc version")
    }
    if let result = message["result"] as? [String: Any] {
        guard let version = result["protocolVersion"] as? String,
            !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .rejected("initialize result has no protocolVersion")
        }
        return .accepted
    }
    if let error = message["error"] as? [String: Any] {
        let detail = error["message"] as? String ?? "initialize returned an MCP error"
        return .rejected(detail)
    }
    return .rejected("initialize response has no result object")
}

private func preflightFailure(
    responseFailure: String?, transportFailure: String?, stderr: Data
) -> SwapError {
    if let responseFailure { return .message(responseFailure) }
    let text: String
    do { text = try strictUTF8(stderr, label: "MCP preflight stderr") } catch {
        return .message("MCP preflight stderr is not valid UTF-8")
    }
    let tail = text.split(whereSeparator: \Character.isNewline).suffix(3).joined(separator: "\n")
    if !tail.isEmpty { return .message(tail) }
    return .message(transportFailure ?? "server exited without answering initialize")
}

private func nulList(_ values: [String], label: String) throws -> Data {
    var data = Data()
    for value in values {
        guard !value.utf8.contains(0) else {
            throw SwapError.message("MCP \(label) contains a NUL byte")
        }
        data.append(contentsOf: value.utf8)
        data.append(0)
    }
    return data
}

private func readChunk(_ descriptor: Int32, label: String) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
    let count = read(descriptor, &bytes, bytes.count)
    guard count >= 0 else {
        throw SwapError.message("could not read \(label): \(posixDescription())")
    }
    return Data(bytes.prefix(count))
}

private func terminateProcessGroup(_ pid: Int32, reaped: inout Bool) {
    if kill(-pid, SIGKILL) != 0, !reaped { _ = kill(pid, SIGKILL) }
    if !reaped {
        var status: Int32 = 0
        if mcp_swap_wait_child(pid, 0, &status) == 1 { reaped = true }
    }
}

private func posixDescription() -> String {
    String(cString: strerror(errno))
}
