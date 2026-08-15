import Foundation
import SpikeSupport

package struct PythonProcessReply: Sendable, Equatable {
    package let standardOutput: [String]
    package let standardError: [String]
    package let termination: ProcessTermination
}

package enum PythonReplySemantics {
    package static func adapt(
        arguments: [String],
        reply: ProcessReply
    ) -> PythonProcessReply {
        var standardOutput = splitOnLineFeed(
            decodeBackslashReplace(reply.standardOutput)
        )
        while standardOutput.last == "" {
            standardOutput.removeLast()
        }
        let standardError = splitOnLineFeed(
            decodeBackslashReplace(reply.standardError)
        )
        .filter { !$0.isEmpty }
        if arguments.contains("has-session"), standardOutput.isEmpty,
            let firstError = standardError.first
        {
            standardOutput = [firstError]
        }
        return PythonProcessReply(
            standardOutput: standardOutput,
            standardError: standardError,
            termination: reply.termination
        )
    }
}

private func splitOnLineFeed(_ value: String) -> [String] {
    value.unicodeScalars.split(
        separator: "\n",
        omittingEmptySubsequences: false
    ).map(String.init)
}

package func decodeBackslashReplace(_ bytes: [UInt8]) -> String {
    var result = ""
    var index = 0
    while index < bytes.count {
        let first = bytes[index]
        if first < 0x80 {
            result.unicodeScalars.append(UnicodeScalar(first))
            index += 1
            continue
        }

        let length: Int
        let scalar: UInt32
        if (0xc2...0xdf).contains(first) {
            length = 2
            scalar = UInt32(first & 0x1f)
        } else if (0xe0...0xef).contains(first) {
            length = 3
            scalar = UInt32(first & 0x0f)
        } else if (0xf0...0xf4).contains(first) {
            length = 4
            scalar = UInt32(first & 0x07)
        } else {
            result += String(format: "\\x%02x", first)
            index += 1
            continue
        }

        guard index + length <= bytes.count else {
            result += String(format: "\\x%02x", first)
            index += 1
            continue
        }
        let continuation = Array(bytes[(index + 1)..<(index + length)])
        let validContinuation = continuation.allSatisfy { (0x80...0xbf).contains($0) }
        let second = continuation.first ?? 0
        let validRange =
            !(first == 0xe0 && second < 0xa0)
            && !(first == 0xed && second > 0x9f)
            && !(first == 0xf0 && second < 0x90)
            && !(first == 0xf4 && second > 0x8f)
        guard validContinuation, validRange else {
            result += String(format: "\\x%02x", first)
            index += 1
            continue
        }
        let value = continuation.reduce(scalar) { ($0 << 6) | UInt32($1 & 0x3f) }
        if let unicodeScalar = UnicodeScalar(value) {
            result.unicodeScalars.append(unicodeScalar)
            index += length
        } else {
            result += String(format: "\\x%02x", first)
            index += 1
        }
    }
    return result
}
