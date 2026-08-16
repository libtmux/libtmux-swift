import Foundation
import LibTmux
import TmuxFixture

// A taste matrix: the same work, carried each way tmux can carry it, measured
// rather than asserted. Every number here is produced by the run that prints
// it — nothing is typed in by hand.
//
//     swift run libtmux-bench

/// The modes measured, and the label each column carries.
///
/// `TmuxMode` is the library's own, so this measures the surface a caller uses
/// rather than a copy of it: every scenario below is handed to `using(_:)`
/// exactly as a program choosing a mode at runtime would.
let modes: [(label: String, mode: TmuxMode)] = [
    ("direct", .direct),
    ("connected", .connected(to: "bench")),
]

/// One unit of work, written once and run under every mode.
struct Scenario {
    let name: String
    let detail: String
    /// Returns a line of output, so the table can show what each mode answered
    /// as well as how long it took.
    let work: @Sendable (Server) async throws -> String
}

let scenarios: [Scenario] = [
    Scenario(
        name: "one listing",
        detail: "list-sessions, once",
        work: { server in
            let sessions = try await server.sessions()
            return sessions.map(\.name).sorted().joined(separator: ",")
        }
    ),
    Scenario(
        name: "twenty listings",
        detail: "list-sessions, twenty times",
        work: { server in
            var last = 0
            for _ in 0..<20 { last = try await server.sessions().count }
            return "\(last) sessions"
        }
    ),
    Scenario(
        name: "snapshot",
        detail: "sessions, windows, panes, clients, twice-checked",
        work: { server in
            let snapshot = try await server.snapshot()
            return
                "\(snapshot.sessions.count)s \(snapshot.windows.count)w "
                + "\(snapshot.panes.count)p \(snapshot.clients.count)c"
        }
    ),
    Scenario(
        name: "four, in turn",
        detail: "sessions, windows, panes, clients — one after another",
        work: { server in
            let sessions = try await server.sessions()
            let windows = try await server.windows()
            let panes = try await server.panes()
            let clients = try await server.clients()
            return "\(sessions.count)s \(windows.count)w \(panes.count)p \(clients.count)c"
        }
    ),
    Scenario(
        name: "four, at once",
        detail: "the same four, concurrently — a pipelined batch",
        work: { server in
            async let sessions = server.sessions()
            async let windows = server.windows()
            async let panes = server.panes()
            async let clients = server.clients()
            let (s, w, p, c) = try await (sessions, windows, panes, clients)
            return "\(s.count)s \(w.count)w \(p.count)p \(c.count)c"
        }
    ),
    Scenario(
        name: "five windows, apart",
        detail: "new-window five times, each its own command",
        work: { server in
            guard let session = try await server.sessions().first else { return "-" }
            for index in 0..<5 {
                _ = try await server.newWindow(in: session, named: "w\(index)")
            }
            return "\(try await server.windows().count) windows"
        }
    ),
    Scenario(
        name: "five windows, listed",
        detail: "the same five as one command list",
        work: { server in
            guard let session = try await server.sessions().first else { return "-" }
            var list = TmuxCommandList()
            for index in 0..<5 {
                list = list.then("new-window", ["-d", "-t", session.id, "-n", "w\(index)"])
            }
            _ = try await server.run(list)
            return "\(try await server.windows().count) windows"
        }
    ),
    Scenario(
        name: "build a window",
        detail: "new-window then split, read back",
        work: { server in
            guard let session = try await server.sessions().first else { return "-" }
            let window = try await server.newWindow(in: session)
            _ = try await server.splitWindow(window)
            let panes = try await server.panes().filter { $0.windowID == window.id }
            return "\(panes.count) panes"
        }
    ),
]

/// What one run of a scenario cost.
///
/// Two counts rather than one, because a mode moves them independently: a
/// connection collapses the processes to one and leaves the round trips where
/// they were. Without both, every connected row reads "1 process" and a command
/// list looks like it buys nothing there.
struct Measurement {
    let elapsed: Duration
    let processes: Int
    let roundTrips: Int
    let output: String
}

// MARK: - Counting what tmux is actually asked to do

/// A stand-in for the tmux binary that records what it is asked and then becomes
/// the real thing. Counting from outside the library keeps the measurement
/// honest: nothing in `LibTmux` knows it is being watched.
struct CountingTmux {
    /// The shim to hand `Server` as its tmux.
    let executable: String
    /// A byte per process started.
    private let spawns: URL
    /// A line per command line submitted to tmux.
    private let submissions: URL

    /// Writes the shim into `directory` and returns it.
    ///
    /// Round trips are countable this precisely because control mode is
    /// line-framed: the library writes one line per command and tmux answers
    /// one block per line. So a copy of what goes past on the way in *is* the
    /// exchange count, with no cooperation from the code being measured.
    init(realTmux: String, at directory: URL) throws {
        spawns = directory.appendingPathComponent("spawns")
        submissions = directory.appendingPathComponent("submissions")
        let script = directory.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        printf 'x' >>'\(spawns.path)'
        printf '.\\n' >>'\(submissions.path)'
        case " $* " in
            *' -C '*)
                # A control client is handed its first command as argv and every
                # later one on stdin, so the stream is copied on its way past.
                #
                # Recorded and flushed *before* the line is forwarded, which is
                # what makes the count safe to read the moment a reply arrives:
                # anything tmux has answered is already on disk. `tee` cannot
                # promise that — it buffers its file copy until it exits, and
                # closing the connection signals the whole process group, so the
                # buffer is usually discarded rather than written.
                #
                # The variable is not called `log`: that is one of gawk's own
                # functions, and naming it so is fatal there rather than
                # shadowed, which reads as the connection closing on its own.
                awk -v recorded='\(submissions.path)' \\
                    '{ print >> recorded; fflush(recorded); print; fflush() }' \\
                    | '\(realTmux)' "$@"
                ;;
            *)
                exec '\(realTmux)' "$@"
                ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        executable = script.path
        try reset()
    }

    /// Forgets everything counted so far. Setting a server up is not the
    /// measurement, so the tallies start at zero once it is running.
    func reset() throws {
        try Data().write(to: spawns)
        try Data().write(to: submissions)
    }

    var processes: Int { (try? Data(contentsOf: spawns).count) ?? 0 }

    var roundTrips: Int {
        guard let data = try? Data(contentsOf: submissions) else { return 0 }
        return data.count { $0 == UInt8(ascii: "\n") }
    }
}

func resolveRealTmux() -> String {
    if let selected = ProcessInfo.processInfo.environment["LIBTMUX_TMUX_BIN"],
        !selected.isEmpty
    {
        return selected
    }
    for candidate in ["/usr/bin/tmux", "/usr/local/bin/tmux", "/opt/homebrew/bin/tmux"]
    where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return "/usr/bin/tmux"
}

// MARK: - Running one cell of the table

/// Where every socket this benchmark creates lives.
///
/// The language is in the name because `/tmp` is shared and several ports of
/// libtmux are worked on side by side: an unscoped `libtmux-…` root lets two of
/// them find each other's servers, and a stray socket then says nothing about
/// which run left it.
let socketRoot = URL(fileURLWithPath: "/tmp/libtmux-swift-dev")

func benchmarkDirectory() throws -> URL {
    let root = socketRoot.appendingPathComponent("\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: socketRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

/// Runs `body` against a tmux server of its own, and reaps it.
///
/// The kill is awaited before the directory goes, because the socket is *in*
/// that directory: a teardown still in flight when the directory is removed has
/// lost the only address it had for the server. What is left behind is a tmux
/// nothing can reach, holding a pty, and the bill arrives runs later as `fork
/// failed: No space left on device` — a benchmark starts a server per scenario
/// per mode per repeat, so the arithmetic is quick.
///
/// ``reaperCommand(root:)`` covers the other half, where this process is killed
/// outright and no teardown of its own runs at all.
func withBenchServer<Result>(
    _ body: (Server, CountingTmux) async throws -> Result
) async throws -> Result {
    let root = try benchmarkDirectory()
    let counting = try CountingTmux(realTmux: resolveRealTmux(), at: root)
    let server = try Server(
        socketPath: root.appendingPathComponent("s").path,
        tmuxExecutable: counting.executable
    )
    _ = try await server.run([
        // As the suite does, and for the same reason: a pane otherwise runs
        // whichever shell the machine is configured with, which would make the
        // streaming figures somebody's dotfiles rather than the library's.
        TmuxCommand("set-option", ["-g", "default-shell", "/bin/sh"]),
        TmuxCommand("new-session", ["-d", "-s", "bench"]),
        reaperCommand(root: root),
    ])

    func reap() async {
        _ = try? await server.run(TmuxCommand("kill-server"))
        try? FileManager.default.removeItem(at: root)
    }

    do {
        // Setting the server up is not the measurement, so the tallies start
        // from zero once it is running.
        try counting.reset()
        let result = try await body(server, counting)
        await reap()
        return result
    } catch {
        await reap()
        throw error
    }
}

func measure(_ scenario: Scenario, mode: TmuxMode) async throws -> Measurement {
    try await withBenchServer { server, counting in
        let clock = ContinuousClock()
        var output = ""

        // One call shape for both modes: that the switch below is a value
        // rather than a branch is the property being measured as much as the
        // timings are.
        let elapsed = try await clock.measure {
            output = try await server.using(mode) { server in
                try await scenario.work(server)
            }
        }

        return Measurement(
            elapsed: elapsed,
            processes: counting.processes,
            roundTrips: counting.roundTrips,
            output: output
        )
    }
}

// MARK: - Reporting

func milliseconds(_ duration: Duration) -> String {
    let value =
        Double(duration.components.attoseconds) / 1e15
        + Double(duration.components.seconds) * 1000
    return String(format: "%7.1f", value)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width
        ? text
        : text + String(repeating: " ", count: width - text.count)
}

/// A count with the noun it counts, so a cell reads as a sentence rather than
/// needing the column header to be understood.
func counted(_ amount: Int, _ singular: String, _ plural: String) -> String {
    "\(amount) \(amount == 1 ? singular : plural)"
}

func cost(_ measured: Measurement) -> String {
    counted(measured.processes, "process", "processes") + ", "
        + counted(measured.roundTrips, "round trip", "round trips")
}

/// Emitting the table is what keeps the documented numbers honest: a figure
/// copied by hand is right once, on the day it was copied.
///
/// The tables are named, because not every page wants both:
/// `Scripts/update_mode_matrix.py` splices whichever sections a file's markers
/// ask for.
let asMarkdown = CommandLine.arguments.contains("--markdown")

if asMarkdown {
    // Kept identical to `HEADER` in `Scripts/update_mode_matrix.py`, which
    // writes the same line into the documents. Two copies of one string, and
    // the `--check` gate is what notices when they disagree.
    print(
        "<!-- generated by `swift run --package-path Benchmarks libtmux-bench"
            + " --markdown`; do not edit -->"
    )
    print("")
    print("<!-- section: modes -->")
    print("| Work | Direct | Connected |")
    print("| --- | --- | --- |")
    for scenario in scenarios {
        var cells: [String] = []
        for (_, mode) in modes {
            cells.append(cost(try await median(scenario, mode: mode)))
        }
        print("| \(scenario.detail) | \(cells[0]) | \(cells[1]) |")
    }
    print("")

    let noticing = try await measureNoticing()
    print("<!-- section: noticing -->")
    print("| Noticing a pane printed a line | Polling | Streaming |")
    print("| --- | --- | --- |")
    print(
        "| tmux processes spent | \(noticing.polled.processes) "
            + "| \(noticing.streamed.processes) |")
    print(
        "| round trips spent | \(noticing.polled.roundTrips) "
            + "| \(noticing.streamed.roundTrips) |")
    print("")

    // Two seconds of quiet: a daemon does not come up the instant it is
    // started, and that gap is the whole difference between the two.
    let waiting = try await measureWaiting(quietFor: .seconds(2))
    print("<!-- section: waiting -->")
    print("| Waiting two seconds for a line you did not print | Polling | waitForOutput |")
    print("| --- | --- | --- |")
    print(
        "| tmux processes spent | \(waiting.polled.processes) "
            + "| \(waiting.awaited.processes) |")
    print(
        "| pane captures taken | \(waiting.polled.output) "
            + "| \(waiting.awaited.output) |")
    exit(0)
}

print("libtmux — how the same work behaves under each mode")
print("tmux: \(resolveRealTmux())")
print("")
print(
    pad("scenario", 22) + pad("mode", 12) + pad("median ms", 12)
        + pad("tmux procs", 12) + pad("round trips", 13) + "answer"
)
print(String(repeating: "-", count: 95))

/// Wall-clock on a shared machine is noisy enough that one sample says more
/// about the neighbours than the mode. Process counts are not — they are the
/// same every run — so only the timing needs repeating.
func median(
    _ scenario: Scenario,
    mode: TmuxMode,
    runs: Int = 5
) async throws -> Measurement {
    var measurements: [Measurement] = []
    for _ in 0..<runs {
        measurements.append(try await measure(scenario, mode: mode))
    }
    let sorted = measurements.sorted { $0.elapsed < $1.elapsed }
    let middle = sorted[sorted.count / 2]
    // If either count varied, the number is not a property of the mode and
    // should not be printed as one — documenting a figure that moves between
    // runs would make the staleness check fail for reasons that say nothing
    // about the code.
    let processes = Set(measurements.map(\.processes))
    precondition(
        processes.count == 1,
        "\(scenario.name)/\(mode) spawned \(processes.sorted()) across runs"
    )
    let trips = Set(measurements.map(\.roundTrips))
    precondition(
        trips.count == 1,
        "\(scenario.name)/\(mode) made \(trips.sorted()) round trips across runs"
    )
    return middle
}

for scenario in scenarios {
    for (label, mode) in modes {
        let measurement = try await median(scenario, mode: mode)
        print(
            pad(scenario.name, 22) + pad(label, 12)
                + pad(milliseconds(measurement.elapsed), 12)
                + pad("\(measurement.processes)", 12)
                + pad("\(measurement.roundTrips)", 13)
                + measurement.output
        )
    }
    print("")
}

// MARK: - Noticing that a pane printed something

/// How long until a caller learns a pane produced a line, and how much it asked
/// tmux in the meantime. Polling has to guess an interval; a connection is told.
///
/// Both sides are charged from the same moment — the pane is found first and
/// costs neither — so streaming pays for opening its connection and polling
/// pays for every tick. That is the honest comparison: the connection is not
/// free, and the ticks are not one-off.
func measureNoticing() async throws -> (polled: Measurement, streamed: Measurement) {
    let marker = "printed-marker"
    let clock = ContinuousClock()

    // Polling: capture the pane on an interval until the line shows up.
    let polled = try await withBenchServer { server, counting in
        guard let pane = try await server.panes().first else { throw BenchError.noPane }
        try counting.reset()
        var ticks = 0
        let elapsed = try await clock.measure {
            try await server.run("echo \(marker)", in: pane)
            while true {
                ticks += 1
                if try await server.capture(pane).contains(where: {
                    $0.contains(marker)
                }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        return Measurement(
            elapsed: elapsed,
            processes: counting.processes,
            roundTrips: counting.roundTrips,
            output: counted(ticks, "tick", "ticks")
        )
    }

    // Streaming: the server says so, unprompted.
    let streamed = try await withBenchServer { server, counting in
        guard let pane = try await server.panes().first else { throw BenchError.noPane }
        try counting.reset()
        return try await server.connected(attachingTo: "bench") { server, events in
            let elapsed = try await clock.measure {
                try await server.run("echo \(marker)", in: pane)
                for await notification in events.notifications
                where notification.arguments.contains(marker) {
                    break
                }
            }
            return Measurement(
                elapsed: elapsed,
                processes: counting.processes,
                roundTrips: counting.roundTrips,
                output: "no tick"
            )
        }
    }

    return (polled, streamed)
}

/// What a wait *for output somebody else produced* costs, which is the case
/// `waitForOutput` exists for and the one the noticing table above does not
/// cover: there the line is already on screen when the first capture runs, so
/// polling never has to tick.
func measureWaiting(quietFor delay: Duration) async throws
    -> (polled: Measurement, awaited: Measurement)
{
    let marker = "listening-marker"
    let clock = ContinuousClock()

    /// Prints the marker after `delay`, the way a daemon coming up does.
    @Sendable func announce(_ server: Server, _ pane: Pane) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: delay)
            try? await server.run("echo \(marker)", in: pane)
        }
    }

    let polled = try await withBenchServer { server, counting in
        guard let pane = try await server.panes().first else { throw BenchError.noPane }
        try counting.reset()
        var ticks = 0
        let announcing = announce(server, pane)
        let elapsed = try await clock.measure {
            while true {
                ticks += 1
                if try await server.capture(pane).contains(where: {
                    $0.contains(marker)
                }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        announcing.cancel()
        return Measurement(
            elapsed: elapsed,
            processes: counting.processes,
            roundTrips: counting.roundTrips,
            output: counted(ticks, "capture", "captures")
        )
    }

    let awaited = try await withBenchServer { server, counting in
        guard let pane = try await server.panes().first else { throw BenchError.noPane }
        try counting.reset()
        let announcing = announce(server, pane)
        let elapsed = try await clock.measure {
            _ = try await server.waitForOutput(
                in: pane,
                matching: [marker],
                requiringFreshOutput: true,
                timeout: .seconds(30)
            )
        }
        announcing.cancel()
        return Measurement(
            elapsed: elapsed,
            processes: counting.processes,
            roundTrips: counting.roundTrips,
            output: counted(1, "capture", "captures")
        )
    }

    return (polled, awaited)
}

enum BenchError: Error { case noPane }

// Five runs here too: a latency claim from one sample is an anecdote.
var polledRuns: [Measurement] = []
var streamedRuns: [Measurement] = []
for _ in 0..<5 {
    let run = try await measureNoticing()
    polledRuns.append(run.polled)
    streamedRuns.append(run.streamed)
}
let noticing = (
    polled: polledRuns.sorted { $0.elapsed < $1.elapsed }[polledRuns.count / 2],
    streamed: streamedRuns.sorted { $0.elapsed < $1.elapsed }[streamedRuns.count / 2]
)
print(String(repeating: "-", count: 95))
print("Noticing that a pane printed a line")
print("")
print(
    pad("approach", 22) + pad("", 12) + pad("median ms", 12) + pad("tmux procs", 12)
        + pad("round trips", 13) + "how it learned")
for (label, measured, how) in [
    ("polling capture", noticing.polled, "asked, on a 50 ms interval"),
    ("streaming", noticing.streamed, "was told, unprompted"),
] {
    print(
        pad(label, 22) + pad("", 12) + pad(milliseconds(measured.elapsed), 12)
            + pad("\(measured.processes)", 12) + pad("\(measured.roundTrips)", 13)
            + "\(how) — \(measured.output)")
}
print("")
print("  This is polling's best case: the line was already on screen when the")
print("  first capture ran. Each further tick it needs is another process and")
print("  another round trip. Streaming spends its connection once and is then")
print("  told, so the wait costs it nothing however long it lasts.")
print("")

print(String(repeating: "-", count: 95))
print("Reading this table")
print("")
print("  A direct call is one tmux process; twenty calls are twenty processes.")
print("  A connection is one process for the whole scope, however many calls")
print("  run inside it — that is the whole of what the mode buys.")
print("")
print("  A round trip is one command line handed to tmux. Directly, a round")
print("  trip is a process, so the two columns agree. Over a connection they")
print("  come apart, and the round trips are what is left to save: a command")
print("  list spends one whatever its length, which is the only place that")
print("  difference is visible.")
print("")
print("  The answers agree across modes except where a connection changes what")
print("  it is measuring: it attaches as a client, so it appears in the client")
print("  count and the session it attached to reads as attached.")
print("")
print("  Process counts are exact and repeat every run. Wall-clock is a median")
print("  of five and still moves with whatever else the machine is doing, so")
print("  read the shape of it rather than the digits.")
print("")
print("  Opening a connection costs something a single call cannot amortise,")
print("  which is why one listing is the row where the two are closest.")
