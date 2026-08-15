import Foundation

/// The environment every tmux this library runs is given.
///
/// Constructed rather than inherited. A tmux that inherits its caller's
/// environment reports whatever that caller's locale asks for, so a listing's
/// separators and a format's bytes would depend on who ran the program rather
/// than on what tmux found — which is why `LC_ALL` is set to `C` and why the
/// rest is left out.
///
/// `TMUX_TMPDIR` is the exception, because it is not about what tmux *prints*
/// but about which server it *reaches*. tmux resolves a socket name inside that
/// directory, so a caller who can see a server by name would otherwise hand
/// this library the same name and be answered about a different one — or about
/// nothing at all. Passing it through is what makes ``Endpoint/socketName(_:)``
/// mean the same server to the library that it means to the caller.
///
/// Both modes read this. A socket name that resolved one way directly and
/// another way over a connection would break the one thing a mode is not
/// allowed to change: what comes back.
enum TmuxProcessEnvironment {
    /// - Parameter environment: where to read `TMUX_TMPDIR` from. Injectable so
    ///   that a caller — or a test — can ask about an environment other than
    ///   its own.
    static func variables(
        readingFrom environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var variables = ["LC_ALL": "C"]
        if let socketDirectory = environment["TMUX_TMPDIR"], !socketDirectory.isEmpty {
            variables["TMUX_TMPDIR"] = socketDirectory
        }
        return variables
    }
}
