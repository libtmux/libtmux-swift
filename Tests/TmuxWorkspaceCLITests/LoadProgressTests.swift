import Foundation
import Testing

@testable import TmuxWorkspaceCLI

@Suite("workspace progress")
struct LoadProgressTests {
    @Test("custom progress reflects completed windows and panes")
    func counters() throws {
        let command = try Load.parse([
            "input", "-d", "--color", "never", "--progress-format",
            "{session}|{window}|{windows_done}/{window_total}|{pane_done}/{pane_total}|{session_panes_done}/{session_pane_total}|{overall_percent}|{{unknown}}|{unknown}",
        ])
        var progress = try #require(
            try LoadProgress.create(command, context: context(columns: 160)))
        progress.update(
            "workspace-started",
            data: .object([
                "session_name": .string("test"), "window_total": .integer(2),
                "session_pane_total": .integer(3),
            ]))
        progress.update(
            "window-created",
            data: .object([
                "window_name": .string("first"), "window_index": .integer(1),
                "pane_total": .integer(2),
            ]))
        progress.update("pane-completed", data: .null)
        progress.update("pane-completed", data: .null)
        progress.update("window-completed", data: .null)
        progress.update(
            "window-created",
            data: .object([
                "window_name": .string("second"), "window_index": .integer(2),
                "pane_total": .integer(1),
            ]))
        progress.update("pane-completed", data: .null)
        let frame = progress.frame()
        #expect(frame == "test|second|1/2|1/1|3/3|100|{unknown}|{unknown}\n")
        let clear = progress.clear()
        #expect(!clear.isEmpty)
        let repeated = progress.clear()
        #expect(repeated.isEmpty)
        progress.update("failed", data: .null)
        let completed = progress.frame()
        #expect(completed == nil)
    }

    @Test("panels bound retained output and sanitize terminal controls", arguments: [0, 3, -1])
    func panel(lines: Int) throws {
        let command = try Load.parse([
            "input", "-d", "--color", "never", "--progress-format", "{session}",
            "--progress-lines", String(lines),
        ])
        var progress = try #require(try LoadProgress.create(command, context: context(columns: 20)))
        progress.update(
            "workspace-started", data: .object(["session_name": .string("wide界\u{1b}[31m")]))
        progress.appendCapturedOutput(
            String(repeating: "old\n", count: 30_000) + "new\nnewer\nnewest\n")
        let rendered = progress.frame()
        let frame = try #require(rendered)
        #expect(!frame.contains("\u{1b}"))
        let rows = frame.split(separator: "\n")
        #expect(rows.count == (lines == 0 ? 1 : lines == -1 ? 5 : 4))
        #expect(rows.first?.contains("\\u001b") == true)
        #expect(rows.allSatisfy { $0.count <= 19 })
        if lines != 0 { #expect(rows.last == "newest") }
    }

    @Test("machine and disabled terminals do not create a progress display")
    func disabled() throws {
        for args in [["--json"], ["--ndjson"], ["--no-progress"]] {
            #expect(
                try LoadProgress.create(Load.parse(["input", "-d"] + args), context: context())
                    == nil)
        }
        for environment in [["TERM": "dumb"], ["TMUXP_PROGRESS": "0"]] {
            var context = context()
            context.environment = environment
            #expect(try LoadProgress.create(Load.parse(["input", "-d"]), context: context) == nil)
        }
        var redirected = context()
        redirected.errorTerminal = false
        #expect(try LoadProgress.create(Load.parse(["input", "-d"]), context: redirected) == nil)
    }

    @Test("captured output preserves blank lines and a bounded Unicode tail")
    func capturedOutput() throws {
        let command = try Load.parse([
            "input", "-d", "--color", "never", "--progress-format", "{window}",
        ])
        var progress = try #require(
            try LoadProgress.create(command, context: context(columns: 100_000)))
        progress.update("workspace-started", data: .null)
        progress.appendCapturedOutput("first\n\nlast\n")
        let blankLines = progress.frame()
        #expect(blankLines == "\nfirst\n\nlast\n")
        _ = progress.clear()
        progress.appendCapturedOutput(String(repeating: "界", count: 30_000) + "tail")
        let rendered = progress.frame()
        let frame = try #require(rendered)
        #expect(frame.hasSuffix("tail\n"))
        #expect(frame.contains("界"))
        #expect(frame.utf8.count <= 65_538)
    }

    private func context(columns: Int = 80) -> CLIContext {
        CLIContext(
            directory: URL(fileURLWithPath: "/tmp/libtmux-swift-test"), environment: [:],
            output: { _ in }, error: { _ in }, errorTerminal: true,
            terminalSize: (columns: columns, rows: 6))
    }
}
