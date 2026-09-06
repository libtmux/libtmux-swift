import Foundation
import LibTmux

extension TmuxTools {
    func pasteText(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        try await guardForCaller().checkPane(
            pane.id, override: try arguments.bool("force", or: false))
        let text = try arguments.string("text")
        let buffer = "libtmux-mcp-\(UUID().uuidString.prefix(8))"
        try await server.setBuffer(text, named: buffer)
        let paste: Result<Void, TmuxError>
        do {
            try await server.paste(buffer: buffer, into: pane)
            paste = .success(())
        } catch {
            paste = .failure(error)
        }
        let cleanup = Task {
            try await server.deleteBuffer(named: buffer)
        }
        try await cleanup.value
        try paste.get()
        return .init(
            Pasted(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue,
                characters: text.count
            )
        )
    }
}
