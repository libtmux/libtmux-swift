import Foundation

package struct BoundedLineFramer: Sendable {
    package enum Event: Sendable, Equatable {
        case line(String)
        case oversized
        case invalidUTF8
    }

    private let maximumBytes: Int
    private let lossyPrefixes: [[UInt8]]
    private var buffer = Data()
    private var discarding = false

    /// - Parameter lossyPrefixes: a line starting with one of these is decoded
    ///   with replacement characters instead of being refused as invalid. For
    ///   a stream whose lines carry raw bytes that were never cut at a
    ///   character boundary.
    package init(maximumBytes: Int, lossyPrefixes: [String] = []) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
        self.lossyPrefixes = lossyPrefixes.map { Array($0.utf8) }
    }

    package var bufferedBytes: Int { buffer.count }

    package mutating func append(_ chunk: Data) -> [Event] {
        var events: [Event] = []
        var start = chunk.startIndex
        while start < chunk.endIndex,
            let newline = chunk[start...].firstIndex(of: 0x0A)
        {
            consume(chunk[start..<newline], endingLine: true, into: &events)
            start = chunk.index(after: newline)
        }
        if start < chunk.endIndex {
            consume(chunk[start...], endingLine: false, into: &events)
        }
        return events
    }

    package mutating func finish() -> [Event] {
        defer {
            buffer.removeAll(keepingCapacity: false)
            discarding = false
        }
        guard !discarding, !buffer.isEmpty else { return [] }
        return [decodeLine()]
    }

    private mutating func consume(
        _ bytes: Data.SubSequence,
        endingLine: Bool,
        into events: inout [Event]
    ) {
        if !discarding {
            if bytes.count > maximumBytes - buffer.count {
                buffer.removeAll(keepingCapacity: false)
                discarding = true
                events.append(.oversized)
            } else {
                buffer.append(contentsOf: bytes)
            }
        }
        guard endingLine else { return }
        if !discarding { events.append(decodeLine()) }
        buffer.removeAll(keepingCapacity: false)
        discarding = false
    }

    private func decodeLine() -> Event {
        var bytes = buffer
        if bytes.last == 0x0D { bytes.removeLast() }
        guard let line = String(data: bytes, encoding: .utf8) else {
            if lossyPrefixes.contains(where: { bytes.starts(with: $0) }) {
                return .line(String(decoding: bytes, as: UTF8.self))
            }
            return .invalidUTF8
        }
        return .line(line)
    }
}
