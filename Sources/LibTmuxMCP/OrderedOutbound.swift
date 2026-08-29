/// Holds complete protocol lines for one ordered writer.
actor OrderedOutbound {
    private struct Submission {
        let line: String
        let accepted: CheckedContinuation<Bool, Never>?
        let delivered: CheckedContinuation<Bool, Never>?
    }

    private enum State {
        case open
        case finishing
        case cancelled
    }

    private let capacity: Int
    private let pendingCapacity: Int
    private var state = State.open
    private var buffered: [Submission] = []
    private var pending: [Submission] = []
    private var activeDelivery: CheckedContinuation<Bool, Never>?
    private var receiver: CheckedContinuation<String?, Never>?

    init(capacity: Int) {
        precondition(capacity > 0 && capacity < Int.max)
        self.capacity = capacity
        // Each admitted request can suspend one submission; the sequential
        // input loop can suspend one more while emitting a protocol error.
        self.pendingCapacity = capacity + 1
    }

    func enqueue(_ line: String) async -> Bool {
        await withCheckedContinuation { accepted in
            submit(Submission(line: line, accepted: accepted, delivered: nil))
        }
    }

    func offer(_ line: String) -> Bool {
        guard state == .open else { return false }
        return admit(Submission(line: line, accepted: nil, delivered: nil))
    }

    func writeAndWait(_ line: String) async -> Bool {
        await withCheckedContinuation { delivered in
            submit(Submission(line: line, accepted: nil, delivered: delivered))
        }
    }

    func next() async -> String? {
        if !buffered.isEmpty {
            return activate(buffered.removeFirst())
        }
        guard state == .open else { return nil }
        return await withCheckedContinuation { continuation in
            precondition(receiver == nil)
            receiver = continuation
        }
    }

    func didWrite() {
        activeDelivery?.resume(returning: true)
        activeDelivery = nil
    }

    func finish() {
        guard state == .open else { return }
        state = .finishing
        if buffered.isEmpty {
            receiver?.resume(returning: nil)
            receiver = nil
        }
    }

    func cancel() {
        guard state != .cancelled else { return }
        state = .cancelled
        receiver?.resume(returning: nil)
        receiver = nil
        for submission in buffered {
            submission.delivered?.resume(returning: false)
        }
        buffered.removeAll()
        for submission in pending {
            submission.accepted?.resume(returning: false)
            submission.delivered?.resume(returning: false)
        }
        pending.removeAll()
        activeDelivery?.resume(returning: false)
        activeDelivery = nil
    }

    private func submit(_ submission: Submission) {
        guard state == .open else {
            submission.accepted?.resume(returning: false)
            submission.delivered?.resume(returning: false)
            return
        }
        if admit(submission) { return }
        if pending.count < pendingCapacity {
            pending.append(submission)
        } else {
            submission.accepted?.resume(returning: false)
            submission.delivered?.resume(returning: false)
        }
    }

    private func admit(_ submission: Submission) -> Bool {
        if let receiver {
            self.receiver = nil
            submission.accepted?.resume(returning: true)
            activeDelivery = submission.delivered
            receiver.resume(returning: submission.line)
            return true
        } else if buffered.count < capacity {
            buffered.append(submission)
            submission.accepted?.resume(returning: true)
            return true
        }
        return false
    }

    private func activate(_ submission: Submission) -> String {
        precondition(activeDelivery == nil)
        activeDelivery = submission.delivered
        if !pending.isEmpty {
            let admitted = pending.removeFirst()
            buffered.append(admitted)
            admitted.accepted?.resume(returning: true)
        }
        return submission.line
    }
}
