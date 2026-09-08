import Foundation
import LibTmux

extension TmuxTools {
    func pasteText(_ arguments: Arguments) async throws -> ToolOutcome {
        let requested = try arguments.string("paneId")
        let text = try arguments.string("text")
        let force = try arguments.bool("force", or: false)
        let initial = try await preflightPaneInput(
            requested,
            scope: .targetOnly,
            force: force,
            operation: "paste_text"
        )
        let staged = text + (try arguments.bool("enter", or: false) ? "\n" : "")
        if staged.isEmpty {
            return .init(
                Pasted(
                    paneRef: WireReferenceCodec.processLocal.reference(to: initial.source),
                    pane: initial.source.id.rawValue,
                    characters: 0
                )
            )
        }
        let reservation = try await Self.reservePaneInput(initial, operation: "paste_text")
        let buffer = "libtmux-mcp-\(UUID().uuidString.prefix(8))"
        do {
            try await server.setBuffer(staged, named: buffer)
        } catch let primaryError {
            do {
                try await deletePasteBuffer(named: buffer)
            } catch {
                await Self.paneRuns.release(reservation)
                throw combinedPasteFailure(primaryError, cleanup: error)
            }
            await Self.paneRuns.release(reservation)
            throw primaryError
        }
        var primaryError: (any Error)?
        do {
            let final = try await preflightPaneInput(
                requested,
                scope: .targetOnly,
                force: force,
                transitionFrom: initial,
                reservation: reservation,
                operation: "paste_text"
            )
            try await server.paste(buffer: buffer, into: final.source)
        } catch {
            primaryError = error
        }
        await Self.paneRuns.release(reservation)
        do {
            try await deletePasteBuffer(named: buffer)
        } catch {
            if let primaryError {
                throw combinedPasteFailure(primaryError, cleanup: error)
            }
            throw error
        }
        if let primaryError { throw primaryError }
        return .init(
            Pasted(
                paneRef: WireReferenceCodec.processLocal.reference(to: initial.source),
                pane: initial.source.id.rawValue,
                characters: text.count
            )
        )
    }

    private func deletePasteBuffer(named buffer: String) async throws {
        let server = server
        let cleanup = Task.detached { () throws -> Void in
            let (events, continuation) = AsyncStream<Result<Void, TmuxError>>.makeStream()
            let deletion = Task.detached {
                do {
                    try await server.deleteBuffer(named: buffer)
                    continuation.yield(.success(()))
                } catch let error as TmuxError {
                    continuation.yield(.failure(error))
                } catch is CancellationError {
                    continuation.yield(.failure(.cancelled))
                } catch {
                    continuation.yield(
                        .failure(.invocationFailed(reason: String(describing: error)))
                    )
                }
            }
            let timeout = Task.detached {
                do {
                    try await Task.sleep(for: .seconds(1))
                    continuation.yield(
                        .failure(
                            .invocationFailed(reason: "paste buffer cleanup timed out")
                        )
                    )
                } catch {}
            }
            var iterator = events.makeAsyncIterator()
            let result =
                await iterator.next()
                ?? .failure(.invocationFailed(reason: "paste buffer cleanup ended unexpectedly"))
            continuation.finish()
            deletion.cancel()
            timeout.cancel()
            try result.get()
        }
        try await cleanup.value
    }

    private func combinedPasteFailure(
        _ primary: any Error,
        cleanup: any Error
    ) -> TmuxError {
        .invocationFailed(
            reason:
                "paste operation failed: \(primary); "
                + "paste buffer cleanup also failed: \(cleanup)"
        )
    }
}
