import Foundation

actor CapturedOutput {
    private let sink: @Sendable (String, String) async throws -> Void
    private var output = UTF8Output()
    private var error = UTF8Output()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var failure: (any Error)?

    init(sink: @escaping @Sendable (String, String) async throws -> Void) {
        self.sink = sink
    }

    var stdout: String { output.value }
    var stderr: String { error.value }

    func append(_ bytes: Data, stream: String, finished: Bool = false) async throws {
        // Readers share a sink, and a suspended write must retain its whole
        // record, so each waits its turn in arrival order.
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        if let failure { throw failure }
        do {
            try Task.checkCancellation()
            let text =
                try stream == "stdout"
                ? output.append(bytes, finished: finished) : error.append(bytes, finished: finished)
            if !text.isEmpty { try await sink(text, stream) }
        } catch {
            failure = error
            throw error
        }
    }
}

struct UTF8Output {
    private var bytes = Data()
    private var pending: [UInt8] = []
    var value: String { String(decoding: bytes, as: UTF8.self) }

    mutating func append(_ chunk: Data, finished: Bool = false) throws -> String {
        guard chunk.count <= 1_048_576 - bytes.count else {
            throw CLIError("process_output_limit", "Child output exceeds 1 MiB on one stream.")
        }
        bytes.append(chunk)
        pending.append(contentsOf: chunk)
        let end = finished ? pending.count : completePrefix()
        let text = String(decoding: pending[..<end], as: UTF8.self)
        pending = Array(pending[end...])
        return text
    }

    private func completePrefix() -> Int {
        guard !pending.isEmpty else { return 0 }
        var start = pending.count - 1
        while start > 0 && pending[start] & 0xC0 == 0x80 && pending.count - start < 4 {
            start -= 1
        }
        let first = pending[start]
        let width: Int
        switch first {
        case 0xC2...0xDF: width = 2
        case 0xE0...0xEF: width = 3
        case 0xF0...0xF4: width = 4
        default: return pending.count
        }
        let count = pending.count - start
        guard count < width else { return pending.count }
        if count > 1 {
            let second = pending[start + 1]
            guard second & 0xC0 == 0x80,
                first != 0xE0 || second >= 0xA0,
                first != 0xED || second <= 0x9F,
                first != 0xF0 || second >= 0x90,
                first != 0xF4 || second <= 0x8F
            else { return pending.count }
        }
        return start
    }
}
