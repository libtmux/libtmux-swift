import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

private let referenceAlphabet = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
)

@Suite("wire references", .timeLimit(.minutes(1)))
struct WireReferenceTests {
    @Test("references are versioned URL-safe opaque values")
    func referencesAreOpaqueAndURLSafe() throws {
        let incarnation = ServerIncarnation(
            endpoint: try Endpoint(socketName: "RAW_ENDPOINT_SENTINEL"),
            socketPath: "RAW_SOCKET_SENTINEL",
            processID: 123_456_789,
            startedAt: 987_654_321
        )
        let pane = Pane(
            id: "%42",
            index: 7,
            width: 80,
            height: 24,
            isActive: true,
            currentCommand: "RAW_COMMAND_SENTINEL",
            currentPath: "/RAW_PATH_SENTINEL",
            windowID: "@8",
            incarnation: incarnation
        )
        let reference = WireReferenceCodec.processLocal.reference(to: pane)
        let payload = try #require(decodedPayload(of: reference))

        #expect(reference.hasPrefix("tmux1_"))
        #expect(
            reference.unicodeScalars.allSatisfy { referenceAlphabet.contains($0) }
        )
        #expect(payload.count == 33)
        for raw in [
            "RAW_ENDPOINT_SENTINEL", "RAW_SOCKET_SENTINEL", "123456789", "987654321",
            "%42",
        ] {
            #expect(
                payload.range(of: Data(raw.utf8)) == nil,
                "the opaque payload contains \(raw)"
            )
        }
    }

    @Test("malformed, future-version, and wrong-kind references are refused")
    func invalidReferencesAreRefused() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            let paneReference = try #require(
                try await tools.call(ToolCall(name: "list_panes"))
                    .structured["panes"]?.arrayValue?.first?["ref"]?.stringValue
            )
            let sessionReference = try #require(
                try await tools.call(ToolCall(name: "list_sessions"))
                    .structured["sessions"]?.arrayValue?.first?["ref"]?.stringValue
            )
            let invalid = [
                "not-a-reference",
                paneReference.replacingOccurrences(of: "tmux1_", with: "tmux2_"),
                sessionReference,
            ]

            for reference in invalid {
                await #expect(throws: ToolError.self) {
                    try await tools.call(
                        ToolCall(
                            name: "capture_pane",
                            arguments: .object(["pane": .string(reference)])
                        )
                    )
                }
            }
        }
    }

    @Test("oversized references are rejected before decoding")
    func oversizedReferencesAreRejected() {
        let oversized = "tmux1_" + String(repeating: "A", count: 1_000_000)
        #expect(throws: WireReferenceCodec.ReferenceError.malformed) {
            try WireReferenceCodec.processLocal.kind(of: oversized)
        }
    }

    @Test("the fingerprint covers every incarnation field")
    func fingerprintCoversTheFullIncarnation() async throws {
        try await withTmuxServer { server in
            let base = try #require(try await server.incarnation())
            let variants = [
                base,
                ServerIncarnation(
                    endpoint: try Endpoint(socketName: "reference-other"),
                    socketPath: base.socketPath,
                    processID: base.processID,
                    startedAt: base.startedAt
                ),
                ServerIncarnation(
                    endpoint: base.endpoint,
                    socketPath: base.socketPath + "-other",
                    processID: base.processID,
                    startedAt: base.startedAt
                ),
                ServerIncarnation(
                    endpoint: base.endpoint,
                    socketPath: base.socketPath,
                    processID: base.processID + 1,
                    startedAt: base.startedAt
                ),
                ServerIncarnation(
                    endpoint: base.endpoint,
                    socketPath: base.socketPath,
                    processID: base.processID,
                    startedAt: base.startedAt + 1
                ),
            ]
            let references = variants.map {
                WireReferenceCodec.processLocal.reference(
                    to: Pane(
                        id: "%0",
                        index: 0,
                        width: 80,
                        height: 24,
                        isActive: true,
                        currentCommand: "sh",
                        currentPath: "/",
                        windowID: "@0",
                        incarnation: $0
                    )
                )
            }
            #expect(Set(references).count == variants.count)

            let client = Client(
                name: "/dev/pts/1",
                tty: "/dev/pts/1",
                processID: 42,
                width: 80,
                height: 24,
                isControlMode: false,
                sessionID: "$0",
                incarnation: base
            )
            let projected = JSONValue.encoding(ClientResult(client))
            #expect(projected["ref"]?.stringValue != nil)
            #expect(projected["incarnation"] == nil)
        }
    }

    @Test("independent codecs cannot accept each other's references")
    func independentCodecsHaveDistinctLocality() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let first = WireReferenceCodec()
            let second = WireReferenceCodec()
            let reference = first.reference(to: pane)

            #expect(reference != second.reference(to: pane))
            #expect(throws: WireReferenceCodec.ReferenceError.stale) {
                try second.resolve(reference, among: [pane])
            }
        }
    }
}

private func decodedPayload(of reference: String) -> Data? {
    guard reference.hasPrefix("tmux1_") else { return nil }
    var encoded = String(reference.dropFirst("tmux1_".count))
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    return Data(base64Encoded: encoded)
}
