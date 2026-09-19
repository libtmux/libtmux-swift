import Testing

extension Trait where Self == TimeLimitTrait {
    /// The time limit a suite in this package sets to catch a hang.
    ///
    /// Swift Testing starts every test in the package at once, and each tmux
    /// command a test runs spawns a process through swift-subprocess, which
    /// forks on one worker thread shared by the whole test process. A test
    /// that finishes in well under a second alone therefore spends most of its
    /// time in the suite queued behind other tests' spawns, and a time limit
    /// counts that queue: a trait scope runs inside the limit too. A limit
    /// shorter than the whole run measures contention on a busy machine, not a
    /// hung test.
    static var hangLimit: Self { .timeLimit(.minutes(5)) }
}
