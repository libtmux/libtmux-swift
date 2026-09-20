import Foundation

package struct BoundedLineFramer: Sendable {
    package enum Event: Sendable, Equatable {
        case line(String)
        case oversized
        case invalidUTF8
    }

    private var bytes: BoundedByteLineFramer

    package init(maximumBytes: Int) {
        bytes = BoundedByteLineFramer(maximumBytes: maximumBytes)
    }

    package var bufferedBytes: Int { bytes.bufferedBytes }

    package mutating func append(_ chunk: Data) -> [Event] {
        bytes.append(chunk).map(Self.decode)
    }

    package mutating func finish() -> [Event] {
        bytes.finish().map(Self.decode)
    }

    private static func decode(_ event: BoundedByteLineFramer.Event) -> Event {
        switch event {
        case let .line(bytes):
            String(data: bytes, encoding: .utf8).map(Event.line) ?? .invalidUTF8
        case .oversized: .oversized
        }
    }
}

struct BoundedByteLineFramer: Sendable {
    enum Event: Sendable, Equatable {
        case line(Data)
        case oversized
    }

    private let maximumBytes: Int
    private var buffer = Data()
    private var discarding = false

    init(maximumBytes: Int) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    var bufferedBytes: Int { buffer.count }

    mutating func append(_ chunk: Data) -> [Event] {
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

    mutating func finish() -> [Event] {
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
        return .line(bytes)
    }
}
