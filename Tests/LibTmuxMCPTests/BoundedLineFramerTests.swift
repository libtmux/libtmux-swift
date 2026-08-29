import Foundation
import LibTmux
import Testing

@testable import LibTmuxMCP

@Suite("bounded line framing")
struct BoundedLineFramerTests {
    @Test("fragmented UTF-8 lines survive chunk boundaries")
    func fragmentedUTF8Survives() {
        var framer = BoundedLineFramer(maximumBytes: 6)
        let bytes = Data("ééé\n".utf8)

        #expect(framer.append(bytes.prefix(1)).isEmpty)
        #expect(framer.append(bytes.dropFirst().prefix(4)).isEmpty)
        #expect(framer.append(bytes.dropFirst(5)) == [.line("ééé")])
        #expect(framer.bufferedBytes == 0)
    }

    @Test("an oversized unterminated line stays bounded and the next line recovers")
    func oversizedLineIsDiscarded() {
        var framer = BoundedLineFramer(maximumBytes: 8)

        #expect(framer.append(Data(repeating: 0x61, count: 100)) == [.oversized])
        #expect(framer.bufferedBytes == 0)
        #expect(framer.append(Data("ignored\nok\n".utf8)) == [.line("ok")])
    }

    @Test("EOF emits a final line and rejects invalid UTF-8")
    func eofAndInvalidUTF8AreExplicit() {
        var final = BoundedLineFramer(maximumBytes: 8)
        #expect(final.append(Data("last".utf8)).isEmpty)
        #expect(final.finish() == [.line("last")])

        var invalid = BoundedLineFramer(maximumBytes: 8)
        #expect(invalid.append(Data([0xFF, 0x0A])) == [.invalidUTF8])
    }
}
