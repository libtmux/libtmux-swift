import Foundation

/// Resolves a bare command name against this process's `PATH`.
///
/// The transport spawns by path and never searches, and the environment it
/// hands tmux carries `LC_ALL=C` and nothing else — so a name with no slash in
/// it is unresolvable at the moment of spawning. Resolving here, against the
/// environment the *caller* was started in, is what lets `tmuxExecutable`
/// default to `"tmux"` and still work.
///
/// A name that resolves to nothing is returned unchanged, so a typo surfaces as
/// the invocation failing rather than as construction failing somewhere the
/// caller was not expecting to handle it.
func resolvedExecutable(
    _ name: String,
    searching environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    guard !name.contains("/") else { return name }
    let searchPath = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
    for directory in searchPath.split(separator: ":") {
        let candidate = "\(directory)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return name
}
