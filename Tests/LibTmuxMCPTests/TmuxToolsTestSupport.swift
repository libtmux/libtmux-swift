import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

extension ToolOutcome {
    /// Decodes what a tool answered, the way a client would.
    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    /// Decodes a listing out of the object it is named inside.
    ///
    /// `structuredContent` is an object in MCP, so a listing answers
    /// `{"panes": [...]}` rather than a bare array.
    func rows<Value: Decodable>(_ name: String, _ type: Value.Type) throws -> [Value] {
        guard let rows = structured[name] else { throw ListingMissing(name: name) }
        return try JSONDecoder().decode(
            [Value].self,
            from: try JSONEncoder().encode(rows)
        )
    }
}

/// Thrown when a listing did not answer under the name its schema promises.
struct ListingMissing: Error {
    let name: String
}

func wireRef(_ pane: Pane) -> String {
    WireReferenceCodec.processLocal.reference(to: pane)
}

func wireRef(_ session: Session) -> String {
    WireReferenceCodec.processLocal.reference(to: session)
}

func wireRef(_ link: WindowLink) -> String {
    WireReferenceCodec.processLocal.reference(to: link)
}

func wireRef(_ window: Window) -> String {
    WireReferenceCodec.processLocal.reference(to: window)
}

func serverRef(_ server: Server) async throws -> String {
    WireReferenceCodec.processLocal.reference(to: try await server.incarnation())
}
