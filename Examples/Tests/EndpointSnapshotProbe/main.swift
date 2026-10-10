import Foundation
import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

let server = try Server()
let changed = ProcessInfo.processInfo.environment["SNAPSHOT_OTHER_ROOT"]!
setenv("LIBTMUX_SOCKET_PATH", "\(changed)/wrong", 1)
setenv("LIBTMUX_SOCKET_NAME", "wrong", 1)
setenv("TMUX_TMPDIR", changed, 1)
setenv("SNAPSHOT_SENTINEL", "changed", 1)
setenv("TMUX", "malformed after construction", 1)
setenv("TMUX_PANE", "%999", 1)
try await server.withNewSession(named: "snapshot", shell: "sleep 300") { session in
    try await server.connected(attachingTo: session.id.rawValue) { connected, _ in
        let sessions = try await connected.sessions()
        guard sessions.map(\.id) == [session.id] else { throw ProbeFailure.wrongSession }
    }
}
guard ProcessInfo.processInfo.environment["SNAPSHOT_SENTINEL"] == "changed" else {
    throw ProbeFailure.hostMutation
}
print("Snapshot retained; host edits preserved")

enum ProbeFailure: Error { case wrongSession, hostMutation }
