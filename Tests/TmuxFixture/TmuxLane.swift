import Foundation
import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Runs `executable` and captures what it prints, without this library.
///
/// `posix_spawn` rather than `Process` or `popen`: this runs while the runner
/// plans tests on several threads, and a fork from a multithreaded process can
/// deadlock in the child before it execs, leaving its pipes open forever.
func spawnCapturing(
    _ executable: String, _ arguments: [String]
) -> (output: String, error: String, status: Int32)? {
    var out: [Int32] = [0, 0]
    var err: [Int32] = [0, 0]
    guard pipe(&out) == 0 else { return nil }
    guard pipe(&err) == 0 else {
        close(out[0])
        close(out[1])
        return nil
    }
    #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
    #else
        var actions = posix_spawn_file_actions_t()
    #endif
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    for descriptor in out + err { posix_spawn_file_actions_addclose(&actions, descriptor) }
    var child: pid_t = 0
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let environment =
        ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { environment.forEach { free($0) } }
    let status = posix_spawn(&child, executable, &actions, nil, argv, environment)
    close(out[1])
    close(err[1])
    guard status == 0 else {
        close(out[0])
        close(err[0])
        return nil
    }
    // A daemon this client started can keep these pipes open after the client
    // is gone, so read what is there until the client exits instead of
    // waiting for end of file.
    for descriptor in [out[0], err[0]] {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    var captured = [Data(), Data()]
    var buffer = [UInt8](repeating: 0, count: 4096)
    func collect() {
        for (index, descriptor) in [out[0], err[0]].enumerated() {
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                captured[index].append(contentsOf: buffer[..<count])
            }
        }
    }
    var wait: Int32 = 0
    while true {
        collect()
        let reaped = waitpid(child, &wait, WNOHANG)
        if reaped == child || reaped < 0 { break }
        usleep(2_000)
    }
    collect()
    close(out[0])
    close(err[0])
    return (
        String(decoding: captured[0], as: UTF8.self),
        String(decoding: captured[1], as: UTF8.self), (wait >> 8) & 0xff
    )
}

/// The release of the lane's tmux executable, read without a fork.
public func tmuxLaneRelease() -> TmuxVersion? {
    let executable = tmuxExecutablePath()
    guard let result = spawnCapturing(executable, ["-V"]),
        let token = result.output.split(whereSeparator: \.isWhitespace).last
    else { return nil }
    return TmuxVersion(parsing: String(token))
}

/// Whether the lane's tmux is at least `major.minor` plus a patch letter.
public func laneAtLeast(_ major: Int, _ minor: Int, _ point: String = "") -> Bool {
    guard let release = tmuxLaneRelease() else { return false }
    return release >= TmuxVersion(major: major, minor: minor, pointRelease: point)
}

/// Library-managed control mode needs a daemon of 3.7 or newer.
public let laneSupportsControl = laneAtLeast(3, 7)

/// Exact named-buffer deletion and rename need 3.4.
public let laneSupportsNamedBufferEditing = laneAtLeast(3, 4)
