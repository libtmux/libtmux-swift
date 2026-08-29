import Foundation

extension Server {
    func expectedIncarnation(
        _ incarnations: [ServerIncarnation]
    ) throws(TmuxError) -> ServerIncarnation {
        guard let expected = incarnations.first else {
            preconditionFailure("a provenance check needs at least one value")
        }
        guard incarnations.allSatisfy({ $0.endpoint == endpoint }) else {
            throw .foreignServerValue
        }
        guard incarnations.allSatisfy({ $0 == expected }) else {
            throw .serverRestarted
        }
        return expected
    }

    func runGuarded(
        _ command: TmuxCommand,
        by values: [GuardedValue],
        checkingTargets: Bool = true
    ) async throws(TmuxError) -> TmuxReply {
        let expected = try expectedIncarnation(values.map(\.incarnation))
        let request = GuardedRequest(
            command: command,
            incarnation: expected,
            targets: checkingTargets ? values.compactMap(\.targetGuard) : []
        )
        let reply: TmuxReply
        if let connection {
            reply = try await connection.reply(to: request)
        } else {
            reply = try await run(rawArguments: request.commands.argumentVector)
        }
        return try request.validate(reply)
    }
}

enum GuardedValue: Sendable {
    case session(Session)
    case window(Window)
    case pane(Pane)
    case client(Client)
    case windowLink(WindowLink)

    var incarnation: ServerIncarnation {
        switch self {
        case let .session(value): value.incarnation
        case let .window(value): value.incarnation
        case let .pane(value): value.incarnation
        case let .client(value): value.incarnation
        case let .windowLink(value): value.incarnation
        }
    }

    var targetGuard: GuardedTarget? {
        switch self {
        case let .session(value):
            GuardedTarget(
                target: value.id.rawValue,
                condition: "#{==:#{session_id},\(value.id.rawValue)}"
            )
        case let .window(value):
            GuardedTarget(
                target: value.id.rawValue,
                condition: "#{==:#{window_id},\(value.id.rawValue)}"
            )
        case let .pane(value):
            GuardedTarget(
                target: value.id.rawValue,
                condition: "#{==:#{pane_id},\(value.id.rawValue)}"
            )
        case .client:
            // `if-shell` has a pane target but no client target. The daemon
            // identity is still guarded atomically and `detach-client` names
            // the exact client; this does not compare client_pid atomically.
            nil
        case let .windowLink(value):
            GuardedTarget(
                target: value.target,
                condition: "#{==:#{window_id},\(value.windowID.rawValue)}"
            )
        }
    }
}

struct GuardedTarget: Sendable {
    let target: String
    let condition: String
}

struct GuardedRequest: Sendable {
    let commands: TmuxCommandList
    let controlLine: String
    let fenceMarker: String
    private let trueMarker: String
    private let staleMarker: String
    private let restartedMarker: String

    init(
        command: TmuxCommand,
        incarnation: ServerIncarnation,
        targets: [GuardedTarget]
    ) {
        let nonce = Self.randomNonce()
        let trueMarker = "\(nonce)_true"
        let staleMarker = "\(nonce)_stale"
        let restartedMarker = "\(nonce)_restarted"
        let fenceMarker = "\(nonce)_fence"
        self.trueMarker = trueMarker
        self.staleMarker = staleMarker
        self.restartedMarker = restartedMarker
        self.fenceMarker = fenceMarker

        var guarded = Self.guardedAction(command, trueMarker: trueMarker)
        for target in targets.reversed() {
            guarded = Self.commandGuard(
                condition: target.condition,
                target: target.target,
                success: guarded,
                failureMarker: staleMarker
            )
        }
        guarded = Self.commandGuard(
            condition: Self.incarnationCondition(incarnation),
            target: nil,
            success: guarded,
            failureMarker: restartedMarker
        )

        let commands = TmuxCommandList([guarded, Self.markerCommand(fenceMarker)])
        self.commands = commands
        self.controlLine = commandListString(commands.commands)
    }

    func validate(_ reply: TmuxReply) throws(TmuxError) -> TmuxReply {
        let expected = [trueMarker, staleMarker, restartedMarker, fenceMarker]
        let markers =
            Self.markers(in: reply.standardOutput, matching: expected)
            + Self.markers(in: reply.standardError, matching: expected)
        guard markers.filter({ $0 == fenceMarker }).count == 1 else {
            throw .invocationFailed(reason: "guarded request returned no final marker")
        }

        let outcomes = markers.filter { $0 != fenceMarker }
        if outcomes == [restartedMarker] {
            throw .serverRestarted
        }
        if outcomes == [staleMarker] {
            throw .staleServerValue
        }

        let cleaned = TmuxReply(
            standardOutput: Self.removing(expected, from: reply.standardOutput),
            standardError: Self.removing(expected, from: reply.standardError),
            exitCode: reply.exitCode
        )
        if outcomes == [trueMarker] || outcomes.isEmpty && !reply.isSuccess {
            return cleaned
        }
        throw .invocationFailed(reason: "guarded request returned an invalid outcome")
    }

    private static func guardedAction(
        _ command: TmuxCommand,
        trueMarker: String
    ) -> TmuxCommand {
        TmuxCommand(
            "if-shell",
            [
                "-F", "1", commandListString([command, markerCommand(trueMarker)]),
                "",
            ]
        )
    }

    private static func commandGuard(
        condition: String,
        target: String?,
        success: TmuxCommand,
        failureMarker: String
    ) -> TmuxCommand {
        var arguments = ["-F"]
        if let target { arguments += ["-t", target] }
        arguments += [
            condition,
            success.parsedString,
            markerCommand(failureMarker).parsedString,
        ]
        return TmuxCommand("if-shell", arguments)
    }

    private static func incarnationCondition(_ incarnation: ServerIncarnation) -> String {
        let processCondition =
            "#{&&:#{==:#{pid},\(incarnation.processID)},"
            + "#{==:#{start_time},\(incarnation.startedAt)}}"
        guard !incarnation.socketPath.contains("\n") else {
            return processCondition
        }
        return
            "#{&&:\(processCondition),"
            + "#{==:#{socket_path},"
            + "\(tmuxFormatComparisonOperand(incarnation.socketPath))}}"
    }

    private static func randomNonce() -> String {
        "__libtmux_request_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func markerCommand(_ marker: String) -> TmuxCommand {
        TmuxCommand("list-commands", ["-F", marker, "display-message"])
    }

    private static func markers(in bytes: [UInt8], matching markers: [String]) -> [String] {
        let encoded = markers.map { ($0, Array($0.utf8)) }
        return byteLines(bytes).compactMap { line in
            encoded.first(where: { line.content.elementsEqual($0.1) })?.0
        }
    }

    private static func removing(_ markers: [String], from bytes: [UInt8]) -> [UInt8] {
        let encoded = markers.map { Array($0.utf8) }
        return byteLines(bytes).reduce(into: []) { result, line in
            guard !encoded.contains(where: { line.content.elementsEqual($0) }) else {
                return
            }
            result.append(contentsOf: line.framed)
        }
    }

    private static func byteLines(
        _ bytes: [UInt8]
    ) -> [(content: ArraySlice<UInt8>, framed: ArraySlice<UInt8>)] {
        var lines: [(ArraySlice<UInt8>, ArraySlice<UInt8>)] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n"))
            let contentEnd = newline ?? bytes.endIndex
            let framedEnd = newline.map { bytes.index(after: $0) } ?? bytes.endIndex
            lines.append((bytes[start..<contentEnd], bytes[start..<framedEnd]))
            start = framedEnd
        }
        return lines
    }
}

private func commandListString(_ commands: [TmuxCommand]) -> String {
    commands.map(\.parsedString).joined(separator: " ; ")
}
