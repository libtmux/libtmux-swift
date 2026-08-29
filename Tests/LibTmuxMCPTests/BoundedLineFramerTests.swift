import Foundation
import LibTmux
import Testing

@testable import LibTmuxMCP

@Suite("bounded line framing")
struct BoundedLineFramerTests {
    @Test("a burst larger than the queue keeps every line")
    func burstIsBackpressured() async throws {
        let filledQueue = DispatchSemaphore(value: 0)
        let stream = AsyncStream<Int>(bufferingPolicy: .bufferingOldest(2)) { continuation in
            let producer = Thread {
                for value in 0..<10 {
                    guard AsyncStreamBackpressure.enqueue(value, to: continuation) else { break }
                    if value == 1 { filledQueue.signal() }
                }
                continuation.finish()
            }
            producer.start()
            filledQueue.wait()
        }

        try await Task.sleep(for: .milliseconds(10))
        var received: [Int] = []
        for await value in stream {
            received.append(value)
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(received == Array(0..<10))
    }

    @Test("ending a full stream releases its producer")
    func terminationEndsBackpressure() async throws {
        let (stream, continuation) = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        #expect(AsyncStreamBackpressure.enqueue(1, to: continuation))
        let (results, resultContinuation) = AsyncStream<Bool>.makeStream()
        let producer = Thread {
            resultContinuation.yield(
                AsyncStreamBackpressure.enqueue(2, to: continuation)
            )
            resultContinuation.finish()
        }
        producer.start()

        try await Task.sleep(for: .milliseconds(20))
        continuation.finish()

        var accepted: Bool?
        for await result in results {
            accepted = result
            break
        }
        #expect(accepted == false)
        _ = stream
    }

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
