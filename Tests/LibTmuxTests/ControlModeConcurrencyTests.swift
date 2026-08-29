import Testing
import TmuxFixture

@testable import LibTmux

private actor ControlSendResult {
    private(set) var value: Result<ControlReply, TmuxError>?

    func record(_ value: Result<ControlReply, TmuxError>) {
        self.value = value
    }
}

private actor ControlWriteLog {
    private(set) var lines: [String] = []

    func record(_ bytes: [UInt8]) {
        lines.append(String(decoding: bytes, as: UTF8.self))
    }
}

private actor FailingSecondControlWriter {
    private(set) var lines: [String] = []

    func write(_ bytes: [UInt8]) throws {
        lines.append(String(decoding: bytes, as: UTF8.self))
        if lines.count == 2 {
            throw TmuxError.connectionClosed
        }
    }
}

@Suite("control mode concurrency", .timeLimit(.minutes(1)))
struct ControlModeConcurrencyTests {
    @Test("an oversized reply fails without shifting the next reply")
    func oversizedReplyPreservesNextReply() async throws {
        let (writes, writeWitness) = AsyncStream.makeStream(of: [UInt8].self)
        let control = ControlSession(
            write: { writeWitness.yield($0) },
            replyByteLimit: 5
        )
        await control.consume("%begin 1 1 0")
        await control.consume("%end 1 1 0")
        var writeIterator = writes.makeAsyncIterator()

        let oversized = Task {
            try await control.send(
                line: "display-message -p first ; display-message -p second",
                commands: 2
            )
        }
        _ = await writeIterator.next()
        await control.consume("%begin 1 2 1")
        await control.consume("12")
        await control.consume("%end 1 2 1")
        await control.consume("%begin 1 3 1")
        await control.consume("34")
        await control.consume("%end 1 3 1")

        await #expect(
            throws: TmuxError.outputLimitExceeded(perStreamBytes: 5)
        ) {
            try await oversized.value
        }

        let next = Task {
            try await control.send(TmuxCommand("display-message", ["-p", "next"]))
        }
        _ = await writeIterator.next()
        await control.consume("%begin 1 4 1")
        await control.consume("ok")
        await control.consume("%end 1 4 1")
        #expect(try await next.value.lines == ["ok"])
    }

    @Test("concurrent sends each receive their own reply")
    func concurrentSendsAreAttributedCorrectly() async throws {
        try await withTmuxServer { server in
            try await server.withControlMode(attachingTo: "bootstrap") { control in
                // Each command prints a distinct marker. If replies are matched
                // by arrival order rather than to their command, some caller
                // gets another's output.
                let replies = try await withThrowingTaskGroup(
                    of: (Int, ControlReply).self
                ) { group in
                    for index in 0..<32 {
                        group.addTask {
                            let reply = try await control.send(
                                TmuxCommand("display-message", ["-p", "marker-\(index)"])
                            )
                            return (index, reply)
                        }
                    }
                    var out: [(Int, ControlReply)] = []
                    for try await pair in group { out.append(pair) }
                    return out
                }
                for (index, reply) in replies {
                    #expect(
                        reply.lines == ["marker-\(index)"],
                        Comment(rawValue: "command \(index) got \(reply.lines)")
                    )
                }
            }
        }
    }

    @Test("cancelling a submitted command preserves later reply attribution")
    func cancelledSendPreservesNextReply() async throws {
        let (writes, writeWitness) = AsyncStream.makeStream(of: [UInt8].self)
        let control = ControlSession(write: { writeWitness.yield($0) })
        await control.consume("%begin 1 1 0")
        await control.consume("%end 1 1 0")

        let firstResult = ControlSendResult()
        let first = Task {
            do {
                let reply = try await control.send(
                    TmuxCommand("display-message", ["-p", "first-command"])
                )
                await firstResult.record(.success(reply))
            } catch let error as TmuxError {
                await firstResult.record(.failure(error))
            } catch {
                Issue.record("unexpected send error: \(error)")
            }
        }
        var writeIterator = writes.makeAsyncIterator()
        let firstWrite = await writeIterator.next()
        #expect(
            firstWrite.map { String(decoding: $0, as: UTF8.self) }
                == "display-message -p first-command\n"
        )

        first.cancel()
        let cancelledPromptly = try await waitUntil(within: .seconds(1)) {
            await firstResult.value != nil
        }
        #expect(cancelledPromptly)

        let second = Task {
            try await control.send(
                TmuxCommand("display-message", ["-p", "second-command"])
            )
        }
        let secondWrite = await writeIterator.next()
        #expect(
            secondWrite.map { String(decoding: $0, as: UTF8.self) }
                == "display-message -p second-command\n"
        )

        await control.consume("%begin 1 2 1")
        await control.consume("first-reply")
        await control.consume("%end 1 2 1")
        await control.consume("%begin 1 3 1")
        await control.consume("second-reply")
        await control.consume("%end 1 3 1")

        _ = try await waitUntil(within: .seconds(1)) {
            await firstResult.value != nil
        }
        #expect(await firstResult.value == .failure(.cancelled))
        #expect(try await second.value.lines == ["second-reply"])
    }

    @Test("cancelling before attachment leaves the connection usable")
    func cancelledAttachWaiterIsRemoved() async throws {
        let writes = ControlWriteLog()
        let control = ControlSession(write: { await writes.record($0) })
        let firstResult = ControlSendResult()
        let (starts, startWitness) = AsyncStream.makeStream(of: Void.self)
        var startIterator = starts.makeAsyncIterator()
        let first = Task { @MainActor in
            startWitness.yield()
            do {
                let reply = try await control.send(
                    TmuxCommand("display-message", ["-p", "cancelled-before-attach"])
                )
                await firstResult.record(.success(reply))
            } catch let error as TmuxError {
                await firstResult.record(.failure(error))
            } catch {
                Issue.record("unexpected send error: \(error)")
            }
        }
        _ = await startIterator.next()
        await control.consume("%begin 1 1 0")

        first.cancel()
        let cancelledPromptly = try await waitUntil(within: .seconds(1)) {
            await firstResult.value != nil
        }
        #expect(cancelledPromptly)
        #expect(await firstResult.value == .failure(.cancelled))
        #expect(await writes.lines.isEmpty)

        await control.consume("%end 1 1 0")
        let second = Task {
            try await control.send(
                TmuxCommand("display-message", ["-p", "after-attach"])
            )
        }
        let wroteSecond = try await waitUntil(within: .seconds(1)) {
            await writes.lines.count == 1
        }
        #expect(wroteSecond)
        #expect(await writes.lines == ["display-message -p after-attach\n"])

        await control.consume("%begin 1 2 1")
        await control.consume("after-attach-reply")
        await control.consume("%end 1 2 1")
        #expect(try await second.value.lines == ["after-attach-reply"])
    }

    @Test("a later write failure cannot shift an earlier reply")
    func laterWriteFailureDoesNotShiftEarlierReply() async throws {
        let writer = FailingSecondControlWriter()
        let control = ControlSession(write: { try await writer.write($0) })
        await control.consume("%begin 1 1 0")
        await control.consume("%end 1 1 0")

        let firstResult = ControlSendResult()
        let first = Task {
            do {
                let reply = try await control.send(
                    TmuxCommand("display-message", ["-p", "first-command"])
                )
                await firstResult.record(.success(reply))
            } catch let error as TmuxError {
                await firstResult.record(.failure(error))
            } catch {
                Issue.record("unexpected first send error: \(error)")
            }
        }
        let wroteFirst = try await waitUntil(within: .seconds(1)) {
            await writer.lines.count == 1
        }
        #expect(wroteFirst)

        let secondResult = ControlSendResult()
        let second = Task {
            do {
                let reply = try await control.send(
                    TmuxCommand("display-message", ["-p", "second-command"])
                )
                await secondResult.record(.success(reply))
            } catch let error as TmuxError {
                await secondResult.record(.failure(error))
            } catch {
                Issue.record("unexpected second send error: \(error)")
            }
        }
        let attemptedSecond = try await waitUntil(within: .seconds(1)) {
            await writer.lines.count == 2
        }
        #expect(attemptedSecond)
        #expect(
            await writer.lines == [
                "display-message -p first-command\n",
                "display-message -p second-command\n",
            ]
        )
        let failedFirst = try await waitUntil(within: .seconds(1)) {
            await firstResult.value != nil
        }
        #expect(failedFirst)

        await control.consume("%begin 1 2 1")
        await control.consume("first-reply")
        await control.consume("%end 1 2 1")

        let answeredSecond = try await waitUntil(within: .seconds(1)) {
            await secondResult.value != nil
        }
        #expect(answeredSecond)
        #expect(await firstResult.value == .failure(.connectionClosed))
        #expect(await secondResult.value == .failure(.connectionClosed))
        await first.value
        await second.value
    }

    @Test("hook replies do not answer the next command")
    func hookRepliesAreDrained() async throws {
        try await withTmuxServer { server in
            let started = "control-hook-started"
            let release = "control-hook-release"
            let set = try await server.setHook(
                "after-display-message",
                to: "wait-for -S \(started) ; wait-for \(release) ; "
                    + "display-message -p hook-output"
            )
            #expect(set.isSuccess, Comment(rawValue: set.errorText))

            try await server.withControlMode(attachingTo: "bootstrap") { control in
                let first = Task {
                    try await control.send(
                        TmuxCommand("display-message", ["-p", "first-reply"])
                    )
                }
                _ = try await server.run(TmuxCommand("wait-for", [started]))
                let next = Task {
                    try await control.send(
                        TmuxCommand("display-message", ["-p", "next-reply"])
                    )
                }
                _ = try await server.run(TmuxCommand("wait-for", ["-S", release]))

                #expect(try await first.value.lines == ["first-reply"])
                #expect(try await next.value.lines == ["next-reply"])
            }
        }
    }

    @Test("protocol-looking command output stays in its reply")
    func protocolLookingOutputStaysInItsReply() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.respawn(
                pane,
                running: ["sh", "-c", "printf '%s\\n' '%end literal'; sleep 5"]
            )
            let printed = try await waitUntil {
                try await server.capture(pane).contains("%end literal")
            }
            #expect(printed)

            try await server.withControlMode(attachingTo: "bootstrap") { control in
                let first = try await control.send(
                    TmuxCommand("capture-pane", ["-p", "-t", pane.id.rawValue])
                )
                #expect(first.lines.contains("%end literal"))

                let next = try await control.send(
                    TmuxCommand("display-message", ["-p", "still-open"])
                )
                #expect(next.lines == ["still-open"])
            }
        }
    }
}
