/// Process-wide record of control-mode client pids this process opened for
/// its own internal use.
///
/// tmux counts every attached client toward `session_attached`, this
/// process's own observation connections included -- so a caller reading a
/// session's attachment while ``Server/waitForOutput(in:matching:stoppingAt:requiringFreshOutput:startingAt:timeout:tailLimit:)``
/// or another internal user of ``Server/connected(attachingTo:_:)`` has one
/// open sees that connection and mistakes it for a person. `Client.processID`
/// matches a registered pid exactly: ``Server/withControlMode(attachingTo:_:)``
/// execs tmux directly, so the connection's process *is* the tmux client tmux
/// reports, not a wrapper around one.
///
/// Scoped process-wide rather than per ``Server`` because a pid is unique to
/// the OS at any instant regardless of which endpoint opened it, and this
/// process only ever opens connections it owns.
package actor OwnedControlClients {
    package static let shared = OwnedControlClients()

    private var pids: Set<Int> = []

    package func register(_ pid: Int) {
        pids.insert(pid)
    }

    package func unregister(_ pid: Int) {
        pids.remove(pid)
    }

    package func contains(_ pid: Int) -> Bool {
        pids.contains(pid)
    }
}
