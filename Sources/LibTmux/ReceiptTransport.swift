import Foundation
import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// Bounded output retained independently of the process task's thrown result.
private actor ReceiptBuffer {
    private var output: [UInt8] = []
    private var error: [UInt8] = []
    private var failure: TmuxError?
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ bytes: [UInt8], toError: Bool) -> Bool {
        let available = max(0, limit - (toError ? error.count : output.count))
        if toError {
            error.append(contentsOf: bytes.prefix(available))
        } else {
            output.append(contentsOf: bytes.prefix(available))
        }
        if bytes.count > available {
            failure = failure ?? tmuxOutputLimitError(limit)
            return false
        }
        return true
    }

    func failed(_ error: TmuxError) { failure = failure ?? error }

    func outcome(exitCode: Int32, fallback: TmuxError? = nil) -> ReceiptOutcome {
        ReceiptOutcome(
            reply: TmuxReply(standardOutput: output, standardError: error, exitCode: exitCode),
            failure: failure ?? fallback)
    }
}

private enum ReceiptCompletion: Sendable {
    case finished(ReceiptOutcome)
    case timedOut
}

extension SubprocessTransport {
    func runReceipted(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async -> ReceiptOutcome {
        let buffer = ReceiptBuffer(limit: perStreamOutputLimit)
        // Lifecycle clients have ten seconds to finish. Caller cancellation is
        // observed after this client drains; it cannot erase an earlier receipt.
        return await withTaskGroup(of: ReceiptCompletion.self) { group in
            group.addTask {
                var options = PlatformOptions()
                options.createSession = true
                options.teardownSequence = [
                    .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .zero)
                ]
                var child: [Subprocess.Environment.Key: String] = [:]
                for (key, value) in environment {
                    guard let name = Subprocess.Environment.Key(rawValue: key) else {
                        return .finished(
                            await buffer.outcome(
                                exitCode: -1,
                                fallback: .processLaunchFailed(reason: "invalid environment key")))
                    }
                    child[name] = value
                }
                do {
                    let result = try await Subprocess.run(
                        Subprocess.Configuration(
                            executable: .path(FilePath(executable)),
                            arguments: Arguments(arguments),
                            environment: .custom(child), platformOptions: options),
                        input: .none, output: .sequence, error: .sequence
                    ) { execution in
                        await withTaskGroup(of: Void.self) { readers in
                            readers.addTask {
                                do {
                                    for try await chunk in execution.standardOutput {
                                        let bytes = chunk.withUnsafeBytes { Array($0) }
                                        if await !buffer.append(bytes, toError: false) {
                                            try? execution.send(signal: .kill, toProcessGroup: true)
                                        }
                                    }
                                } catch { await buffer.failed(normalizedTmuxError(error)) }
                            }
                            readers.addTask {
                                do {
                                    for try await chunk in execution.standardError {
                                        let bytes = chunk.withUnsafeBytes { Array($0) }
                                        if await !buffer.append(bytes, toError: true) {
                                            try? execution.send(signal: .kill, toProcessGroup: true)
                                        }
                                    }
                                } catch { await buffer.failed(normalizedTmuxError(error)) }
                            }
                        }
                    }
                    let code: Int32
                    switch result.terminationStatus {
                    case let .exited(value): code = Int32(value)
                    case let .signaled(value): code = -Int32(value)
                    }
                    return .finished(await buffer.outcome(exitCode: code))
                } catch {
                    return .finished(
                        await buffer.outcome(exitCode: -1, fallback: normalizedTmuxError(error)))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return .timedOut
            }
            let first = await group.next()!
            group.cancelAll()
            switch first {
            case let .finished(outcome): return outcome
            case .timedOut:
                var last: ReceiptOutcome?
                while let next = await group.next() {
                    if case let .finished(outcome) = next { last = outcome }
                }
                let reply =
                    last?.reply ?? TmuxReply(standardOutput: [], standardError: [], exitCode: -1)
                return ReceiptOutcome(
                    reply: reply,
                    failure: .invocationFailed(reason: "lifecycle client exceeded ten seconds"))
            }
        }
    }
}
