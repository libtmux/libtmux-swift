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
        let buffer = "libtmux-mcp-\(UUID().uuidString.prefix(8))"
        do {
            try await server.setBuffer(staged, named: buffer)
        } catch {
            try? await server.deleteBuffer(named: buffer)
            throw error
        }
        let paste: Result<Void, TmuxError>
        do {
            let final = try await preflightPaneInput(
                requested,
                scope: .targetOnly,
                force: force,
                transitionFrom: initial,
                operation: "paste_text"
            )
            let reservation = try await Self.reservePaneInput(final, operation: "paste_text")
            do {
                try await server.paste(buffer: buffer, into: final.source)
            } catch {
                await Self.paneRuns.release(reservation)
                throw error
            }
            await Self.paneRuns.release(reservation)
            paste = .success(())
        } catch let error as TmuxError {
            paste = .failure(error)
        } catch {
            let cleanup = Task { try await server.deleteBuffer(named: buffer) }
            try await cleanup.value
            throw error
        }
        let cleanup = Task {
            try await server.deleteBuffer(named: buffer)
        }
        try await cleanup.value
        try paste.get()
        return .init(
            Pasted(
                paneRef: WireReferenceCodec.processLocal.reference(to: initial.source),
                pane: initial.source.id.rawValue,
                characters: text.count
            )
        )
    }
}
