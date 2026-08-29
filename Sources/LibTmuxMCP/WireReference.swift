import Foundation
import LibTmux

/// A process-local handle for one model value on one tmux daemon incarnation.
///
/// The fingerprint prevents accidental stale targeting. It is not an
/// authorization token, and a new MCP process deliberately produces different
/// references for the same tmux objects.
struct WireReferenceCodec: Sendable {
    static let processLocal = WireReferenceCodec()

    private let processNonce: UUID

    init(processNonce: UUID = UUID()) {
        self.processNonce = processNonce
    }

    enum Kind: UInt8, Sendable, Hashable {
        case session = 1
        case window = 2
        case windowLink = 3
        case pane = 4
        case server = 5
        case client = 6
    }

    enum ReferenceError: Error, Sendable, Hashable {
        case malformed
        case unsupportedVersion
        case wrongKind(expected: Kind, actual: Kind)
        case stale
    }

    private struct Decoded: Sendable, Hashable {
        let kind: Kind
        let fingerprint: [UInt8]
        let subjectFingerprint: [UInt8]
    }

    private static let prefix = "tmux1_"
    private static let payloadBytes = 33
    private static let maximumReferenceBytes = 64

    func reference<Value: WireReferenceSubject>(to value: Value) -> String {
        var payload = [Value.referenceKind.rawValue]
        payload.append(contentsOf: fingerprint(of: value.incarnation))
        payload.append(contentsOf: fingerprint(of: value.referenceSubject))
        return Self.prefix + Data(payload).base64URLEncodedString()
    }

    func resolve<Value: WireReferenceSubject>(
        _ rawValue: String,
        among values: [Value]
    ) throws(ReferenceError) -> Value {
        let decoded = try decode(rawValue)
        guard decoded.kind == Value.referenceKind else {
            throw .wrongKind(expected: Value.referenceKind, actual: decoded.kind)
        }
        guard
            let value = values.first(where: {
                fingerprint(of: $0.referenceSubject) == decoded.subjectFingerprint
                    && fingerprint(of: $0.incarnation) == decoded.fingerprint
            })
        else { throw .stale }
        return value
    }

    func kind(of rawValue: String) throws(ReferenceError) -> Kind {
        try decode(rawValue).kind
    }

    private func decode(_ rawValue: String) throws(ReferenceError) -> Decoded {
        guard rawValue.utf8.count <= Self.maximumReferenceBytes else { throw .malformed }
        guard rawValue.hasPrefix("tmux") else { throw .malformed }
        guard rawValue.hasPrefix(Self.prefix) else { throw .unsupportedVersion }
        let encoded = String(rawValue.dropFirst(Self.prefix.count))
        guard
            !encoded.isEmpty,
            encoded.unicodeScalars.allSatisfy({ Self.urlAlphabet.contains($0) }),
            let payload = Data(base64URLEncoded: encoded),
            payload.count == Self.payloadBytes,
            let kind = Kind(rawValue: payload[0])
        else { throw .malformed }
        return Decoded(
            kind: kind,
            fingerprint: Array(payload[1..<17]),
            subjectFingerprint: Array(payload[17..<33])
        )
    }

    private func fingerprint(of incarnation: ServerIncarnation) -> [UInt8] {
        words(of: hash(incarnation, purpose: "incarnation", domain: 0))
            + words(of: hash(incarnation, purpose: "incarnation", domain: 1))
    }

    private func fingerprint(of subject: String) -> [UInt8] {
        words(of: hash(subject, purpose: "subject", domain: 0))
            + words(of: hash(subject, purpose: "subject", domain: 1))
    }

    private func hash(
        _ value: some Hashable,
        purpose: String,
        domain: UInt8
    ) -> UInt64 {
        var hasher = Hasher()
        hasher.combine("libtmux-mcp-wire-reference")
        hasher.combine(processNonce)
        hasher.combine(purpose)
        hasher.combine(domain)
        hasher.combine(value)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private func words(of value: UInt64) -> [UInt8] {
        (0..<8).map { shift in
            UInt8(truncatingIfNeeded: value >> ((7 - shift) * 8))
        }
    }

    private static let urlAlphabet = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    )
}

protocol WireReferenceSubject {
    static var referenceKind: WireReferenceCodec.Kind { get }
    var referenceSubject: String { get }
    var incarnation: ServerIncarnation { get }
}

extension Session: WireReferenceSubject {
    static let referenceKind = WireReferenceCodec.Kind.session
    var referenceSubject: String { id.rawValue }
}

extension Window: WireReferenceSubject {
    static let referenceKind = WireReferenceCodec.Kind.window
    var referenceSubject: String { id.rawValue }
}

extension WindowLink: WireReferenceSubject {
    static let referenceKind = WireReferenceCodec.Kind.windowLink
    // This is the exact relation address, not a creation-event id. Recreating
    // the same session/index/window relation therefore recreates the same ref.
    var referenceSubject: String {
        "\(sessionID.rawValue):\(index):\(windowID.rawValue)"
    }
}

extension Pane: WireReferenceSubject {
    static let referenceKind = WireReferenceCodec.Kind.pane
    var referenceSubject: String { id.rawValue }
}

extension ServerIncarnation: WireReferenceSubject {
    static let referenceKind = WireReferenceCodec.Kind.server
    var referenceSubject: String { "server" }
    var incarnation: ServerIncarnation { self }
}

extension Client: WireReferenceSubject {
    static let referenceKind = WireReferenceCodec.Kind.client
    var referenceSubject: String {
        "\(name)\u{1f}\(tty)\u{1f}\(processID)\u{1f}\(sessionID.rawValue)"
    }
}

extension WireReferenceCodec {
    func resolve<Value: WireReferenceSubject>(
        _ rawValue: String,
        among values: [Value],
        argument: String,
        refreshWith listing: String
    ) throws -> Value {
        do {
            return try resolve(rawValue, among: values)
        } catch let error {
            switch error {
            case .malformed, .unsupportedVersion, .wrongKind:
                throw ToolError.wrongArgumentType(
                    argument,
                    expected: "a current \(Value.referenceKind.name) ref returned by \(listing)"
                )
            case .stale:
                throw ToolError.refusedForSafety(
                    "the \(Value.referenceKind.name) reference is stale; call \(listing) again"
                )
            }
        }
    }

    func checkedKind(
        of rawValue: String,
        argument: String,
        refreshWith listing: String
    ) throws -> Kind {
        do {
            return try kind(of: rawValue)
        } catch {
            throw ToolError.wrongArgumentType(
                argument,
                expected: "a current object ref returned by \(listing)"
            )
        }
    }
}

private extension WireReferenceCodec.Kind {
    var name: String {
        switch self {
        case .session: "session"
        case .window: "window"
        case .windowLink: "window-link"
        case .pane: "pane"
        case .server: "server"
        case .client: "client"
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 =
            text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        self.init(base64Encoded: base64)
    }
}
