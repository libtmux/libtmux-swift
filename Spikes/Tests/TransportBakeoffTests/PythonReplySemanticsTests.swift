import Foundation
import Testing

@testable import SpikeSupport
@testable import TransportBakeoff

extension TransportBakeoffSuite {
    @Suite("Python reply semantics")
    struct PythonReplySemanticsTests {
        @Test("invalid UTF-8 uses Python backslash replacement escapes")
        func invalidUTF8UsesPythonBackslashReplacementEscapes() {
            let adapted = PythonReplySemantics.adapt(
                arguments: ["display-message"],
                reply: ProcessReply(
                    standardOutput: [0xff] + Array("out\n".utf8),
                    standardError: [0xfe] + Array("err\n".utf8),
                    termination: .exited(7)
                )
            )

            #expect(adapted.standardOutput == ["\\xffout"])
            #expect(adapted.standardError == ["\\xfeerr"])
            #expect(adapted.termination == .exited(7))
        }

        @Test("stdout drops only trailing empty lines and stderr drops every empty line")
        func emptyLinePoliciesMatchPython() {
            let adapted = PythonReplySemantics.adapt(
                arguments: ["display-message"],
                reply: ProcessReply(
                    standardOutput: Array("one\n\ntwo\n\n".utf8),
                    standardError: Array("left\n\nright\n".utf8),
                    termination: .exited(0)
                )
            )

            #expect(adapted.standardOutput == ["one", "", "two"])
            #expect(adapted.standardError == ["left", "right"])
        }

        @Test("has-session mirrors the first stderr line when stdout is empty")
        func hasSessionMirrorsFirstStderrLine() {
            let adapted = PythonReplySemantics.adapt(
                arguments: ["-S", "socket", "has-session", "-t", "missing"],
                reply: ProcessReply(
                    standardOutput: [],
                    standardError: Array("can't find session: missing\nsecond\n".utf8),
                    termination: .exited(1)
                )
            )

            #expect(adapted.standardOutput == ["can't find session: missing"])
            #expect(adapted.standardError == ["can't find session: missing", "second"])
        }

        @Test(
            "invalid UTF-8 spans escape each byte in lowercase",
            arguments: [
                ([0x80], "\\x80"),
                ([0xc0, 0xaf], "\\xc0\\xaf"),
                ([0xe2, 0x28, 0xa1], "\\xe2(\\xa1"),
                ([0xe2, 0x82], "\\xe2\\x82"),
                ([0xed, 0xa0, 0x80], "\\xed\\xa0\\x80"),
                ([0xf4, 0x90, 0x80, 0x80], "\\xf4\\x90\\x80\\x80"),
                ([0xff], "\\xff"),
            ]
        )
        func invalidUTF8SpansEscapeEachByteInLowercase(_ bytes: [UInt8], _ expected: String) {
            let adapted = PythonReplySemantics.adapt(
                arguments: [],
                reply: ProcessReply(
                    standardOutput: bytes,
                    standardError: [],
                    termination: .exited(0)
                )
            )
            #expect(adapted.standardOutput == [expected])
        }

        @Test("valid non-ASCII and carriage returns are preserved")
        func validNonASCIIAndCarriageReturnsArePreserved() {
            let adapted = PythonReplySemantics.adapt(
                arguments: [],
                reply: ProcessReply(
                    standardOutput: Array("héllo\r\ninside\rvalue\n".utf8),
                    standardError: [],
                    termination: .exited(0)
                )
            )
            #expect(adapted.standardOutput == ["héllo\r", "inside\rvalue"])
        }

        @Test(
            "line splitting follows Python LF code-point policy",
            arguments: [
                ([], []),
                (Array("\n".utf8), []),
                (Array("left\r\nright\n".utf8), ["left\r", "right"]),
                (Array("left\rright".utf8), ["left\rright"]),
            ]
        )
        func lineSplittingFollowsPythonLFCodePointPolicy(
            _ bytes: [UInt8],
            _ expected: [String]
        ) {
            let adapted = PythonReplySemantics.adapt(
                arguments: [],
                reply: ProcessReply(
                    standardOutput: bytes,
                    standardError: [],
                    termination: .exited(0)
                )
            )
            #expect(adapted.standardOutput == expected)
        }

        @Test("has-session matching uses exact argv membership")
        func hasSessionMatchingUsesExactArgvMembership() {
            let adapted = PythonReplySemantics.adapt(
                arguments: ["has-session-extra"],
                reply: ProcessReply(
                    standardOutput: [],
                    standardError: Array("error\n".utf8),
                    termination: .exited(1)
                )
            )
            #expect(adapted.standardOutput == [])
        }

        @Test("frozen Python oracle matches decoder and line policy")
        func frozenPythonOracleMatchesDecoderAndLinePolicy() throws {
            guard let path = ProcessInfo.processInfo.environment["LIBTMUX_PYTHON_REPLY_ORACLE"],
                path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: path)
            else { throw PythonOracleFixtureError.missing }
            let oracle = try JSONDecoder().decode(
                PythonReplyOracle.self,
                from: Data(contentsOf: URL(fileURLWithPath: path))
            )

            #expect(oracle.documentKind == "libtmux.python-reply-oracle")
            #expect(oracle.schemaVersion == 1)
            #expect(oracle.generator.sourceSHA256.count == 64)
            #expect(oracle.singleByte.count == 256)
            #expect(Set(oracle.singleByte.map(\.hex)).count == 256)
            for vector in oracle.singleByte + oracle.multibyte {
                #expect(decodeBackslashReplace(try decodeHex(vector.hex)) == vector.decoded)
            }
            for vector in oracle.linePolicy {
                let adapted = PythonReplySemantics.adapt(
                    arguments: vector.arguments,
                    reply: ProcessReply(
                        standardOutput: try decodeHex(vector.stdoutHex),
                        standardError: try decodeHex(vector.stderrHex),
                        termination: .exited(0)
                    )
                )
                #expect(adapted.standardOutput == vector.expectedStdout)
                #expect(adapted.standardError == vector.expectedStderr)
                #expect(adapted.termination == .exited(0))
            }
        }
    }
}

private enum PythonOracleFixtureError: Error {
    case missing
    case invalidHex
}

private struct PythonReplyOracle: Decodable {
    let documentKind: String
    let schemaVersion: Int
    let generator: Generator
    let singleByte: [DecodeVector]
    let multibyte: [DecodeVector]
    let linePolicy: [LineVector]

    struct Generator: Decodable {
        let sourceSHA256: String
    }

    struct DecodeVector: Decodable {
        let hex: String
        let decoded: String
    }

    struct LineVector: Decodable {
        let arguments: [String]
        let stdoutHex: String
        let stderrHex: String
        let expectedStdout: [String]
        let expectedStderr: [String]
    }
}

private func decodeHex(_ value: String) throws -> [UInt8] {
    guard value.count.isMultiple(of: 2) else { throw PythonOracleFixtureError.invalidHex }
    var bytes: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
        let end = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<end], radix: 16) else {
            throw PythonOracleFixtureError.invalidHex
        }
        bytes.append(byte)
        index = end
    }
    return bytes
}
