import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("navigation and buffers", .timeLimit(.minutes(5)))
struct NavigationTests {
    @Test("selecting changes which object is active")
    func selectingChangesWhatIsActive() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "select")
            let first = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let second = try await server.newWindow(in: session, named: "second").window
            let links = try await server.windowLinks()
            let firstLink = try #require(links.first { $0.windowID == first.id })
            let secondLink = try #require(links.first { $0.windowID == second.id })

            try await server.select(secondLink)
            var snapshot = try await server.snapshot()
            #expect(
                snapshot.windowLinks(of: session).first { $0.windowID == second.id }?
                    .isActive == true
            )

            try await server.select(firstLink)
            snapshot = try await server.snapshot()
            #expect(
                snapshot.windowLinks(of: session).first { $0.windowID == first.id }?
                    .isActive == true
            )
        }
    }

    @Test("next, previous, and last move between windows")
    func navigationMovesBetweenWindows() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "walk")
            let first = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let second = try await server.newWindow(in: session).window
            let firstLink = try #require(
                try await server.windowLinks().first { $0.windowID == first.id }
            )

            // Active is per session, so this asks about this session's
            // windows rather than every window on the server.
            func active() async throws -> WindowID? {
                try await server.snapshot()
                    .windowLinks(of: session)
                    .first { $0.isActive }?
                    .windowID
            }

            try await server.select(firstLink)
            try await server.selectNextWindow(in: session)
            #expect(try await active() == second.id)

            try await server.selectPreviousWindow(in: session)
            #expect(try await active() == first.id)

            try await server.selectLastWindow(in: session)
            #expect(try await active() == second.id)
        }
    }

    @Test("swapping moves positions and leaves identities alone")
    func swappingLeavesIdentitiesAlone() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "swap")
            let first = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let second = try await server.newWindow(in: session).window
            let links = try await server.windowLinks()
            let firstLink = try #require(links.first { $0.windowID == first.id })
            let secondLink = try #require(links.first { $0.windowID == second.id })
            let firstIndex = firstLink.index

            try await server.swap(firstLink, with: secondLink)

            let movedLinks = try await server.windowLinks()
            let movedFirst = try #require(movedLinks.first { $0.windowID == first.id })
            let movedSecond = try #require(movedLinks.first { $0.windowID == second.id })
            // The ids you already hold stay valid; only the indices moved.
            #expect(movedFirst.index != firstIndex)
            #expect(movedSecond.index == firstIndex)
        }
    }

    @Test("breaking a pane out gives it a window of its own")
    func breakingAPaneGivesItAWindow() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "break")
            let window = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let extra = try await server.splitWindow(window)
            let source = try #require(
                try await server.windowLinks().first { $0.windowID == window.id }
            )

            let broken = try await server.breakPane(extra, from: source, named: "broken")
            #expect(broken.window.name == "broken")
            #expect(broken.link.sessionID == session.id)
            #expect(broken.link.windowID == broken.window.id)

            let snapshot = try await server.snapshot()
            #expect(snapshot.panes(of: broken.window).map(\.id) == [extra.id])
            #expect(snapshot.panes(of: window).count == 1)
        }
    }

    @Test("joining moves a pane into another window")
    func joiningMovesAPane() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "join")
            let first = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let second = try await server.newWindow(in: session).window
            let pane = try #require(
                try await server.snapshot().panes(of: second).first
            )

            try await server.join(pane, into: first, direction: .left)

            let snapshot = try await server.snapshot()
            #expect(snapshot.panes(of: first).count == 2)
            // The window it left had only that pane, so it went with it.
            #expect(!snapshot.windows.contains { $0.id == second.id })
            // Joining takes a side like a split does, so the moved pane is
            // where it was asked to go rather than wherever tmux defaults to.
            let moved = try #require(snapshot.panes(of: first).first { $0.id == pane.id })
            #expect(moved.isAtLeft && !moved.isAtRight)
        }
    }

    @Test("a buffer round-trips through the server")
    func bufferRoundTrips() async throws {
        try await withTmuxServer { server in
            try await server.setBuffer("held text", named: "mine")
            let contents = try await server.buffer(named: "mine")
            #expect(contents == "held text")

            let buffers = try await server.buffers()
            #expect(buffers.contains { $0.name == "mine" })

            try await server.deleteBuffer(named: "mine")
            let after = try await server.buffers()
            #expect(!after.contains { $0.name == "mine" })
        }
    }

    @Test("a buffer carrying spaces and quotes survives")
    func bufferSurvivesAdversarialText() async throws {
        try await withTmuxServer { server in
            let text = #"two words 'quoted' "double" ;semi"#
            try await server.setBuffer(text, named: "odd")
            let contents = try await server.buffer(named: "odd")
            #expect(contents == text)
        }
    }

    @Test("requireRunning and listings both reject an absent server")
    func requireRunningAgreesWithStrictListings() async throws {
        try await withTmuxServer { server in
            // A running server: no throw, whatever it does or does not hold.
            try await server.requireRunning()

            try await server.killServer()
            await #expect(throws: TmuxError.self) {
                try await server.requireRunning()
            }
            await #expect(throws: TmuxError.self) {
                _ = try await server.sessions()
            }
        }
    }

    @Test("clearing history leaves the pane alive")
    func clearingHistoryLeavesThePaneAlive() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "clear")
            let window = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let pane = try #require(
                try await server.snapshot().panes(of: window).first
            )

            try await server.clearHistory(pane)
            let panes = try await server.panes()
            #expect(panes.contains { $0.id == pane.id })
        }
    }

    @Test("pane modes can be entered and idempotently cancelled")
    func paneModesCanBeCancelled() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)

            func paneInMode() async throws -> String {
                let reply = try await server.run(
                    TmuxCommand(
                        "display-message",
                        ["-p", "-t", pane.id.rawValue, "#{pane_in_mode}"]
                    )
                )
                #expect(reply.isSuccess, Comment(rawValue: reply.errorText))
                return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            try await server.enterCopyMode(pane)
            #expect(try await paneInMode() == "1")
            #expect(try await server.panes().first { $0.id == pane.id }?.modeCount == 1)

            try await server.cancelModes(in: pane)
            #expect(try await paneInMode() == "0")
            #expect(try await server.panes().first { $0.id == pane.id }?.modeCount == 0)
            try await server.cancelModes(in: pane)
            #expect(try await paneInMode() == "0")

            let clock = try await server.run(
                TmuxCommand("clock-mode", ["-t", pane.id.rawValue])
            )
            #expect(clock.isSuccess, Comment(rawValue: clock.errorText))
            #expect(try await paneInMode() == "1")
            try await server.cancelModes(in: pane)
            #expect(try await paneInMode() == "0")
        }
    }

    @Test("a pasted buffer reaches the pane it was addressed to")
    func pasteReachesThePane() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let marker = "libtmux-paste-marker"
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("libtmux-swift-paste-\(UUID().uuidString.prefix(8))")
            try Data("echo \(marker)\n".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            try await server.loadBuffer(from: file.path, named: "probe")
            try await server.paste(buffer: "probe", into: pane)

            // The trailing newline in the buffer is what makes the pane's shell
            // run what was pasted rather than leave it on the prompt.
            let arrived = try await waitUntil {
                try await server.capture(pane).contains { $0.contains(marker) }
            }
            #expect(arrived, "the buffer never reached the pane")
        }
    }

    @Test("linking puts one window in two sessions, and unlinking takes it out of one")
    func linkAndUnlinkMoveOneWindowBetweenSessions() async throws {
        try await withTmuxServer { server in
            let source = try await server.newSession(named: "source", windowName: "shared")
            let target = try await server.newSession(named: "target")
            let shared = try #require(
                try await server.snapshot().windows(of: source).first { $0.name == "shared" }
            )

            let inTarget = try await server.link(shared, into: target)

            // Naming which session gained the window is what tells a `-s`/`-t`
            // swap apart from the correct call.
            let linked = try await server.windowLinks().filter { $0.windowID == shared.id }
            #expect(linked.count == 2)
            #expect(Set(linked.map(\.sessionID)) == [source.id, target.id])

            try await server.unlink(inTarget)

            let remaining = try await server.windowLinks().filter { $0.windowID == shared.id }
            #expect(remaining.map(\.sessionID) == [source.id])
        }
    }

    @Test("moving a window within its source session is refused")
    func moveWithinItsSourceSessionIsRefused() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let source = try #require(
                try await server.windowLinks().first { $0.sessionID == session.id }
            )

            await #expect(throws: TmuxError.self) {
                try await server.move(source, to: session)
            }
            #expect(try await server.windowLinks().contains { $0.id == source.id })
        }
    }

    @Test("a pane title is set on the pane it names")
    func setTitleNamesItsPane() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            let second = try await server.splitWindow(window, direction: .right)
            let first = try #require(
                try await server.panes().first { $0.windowID == window.id && $0.id != second.id }
            )
            let link = try #require(
                try await server.windowLinks().first { $0.windowID == window.id }
            )

            try await server.setTitle("probe-title", of: second)

            #expect(
                try await server.format("#{pane_title}", for: second, through: link)
                    == "probe-title"
            )
            #expect(
                try await server.format("#{pane_title}", for: first, through: link)
                    != "probe-title"
            )
        }
    }

    @Test("sourcing a file runs the commands in it")
    func sourceFileRunsWhatIsInIt() async throws {
        try await withTmuxServer { server in
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("libtmux-swift-source-\(UUID().uuidString.prefix(8)).conf")
            try Data("new-session -d -s from-a-file\n".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            try await server.sourceFile(file.path)

            let exists = try await server.hasSession("from-a-file")
            #expect(exists)
        }
    }

    @Test("starting an already-running server is a no-op rather than an error")
    func startServerIsIdempotent() async throws {
        try await withTmuxServer { server in
            let before = try await server.sessions().map(\.id)
            try await server.startServer()
            let after = try await server.sessions().map(\.id)
            #expect(before == after)
        }
    }

    @Test("next and previous layout move between layouts and back")
    func layoutsCycleBothWays() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            _ = try await server.splitWindow(window, direction: .right)
            let link = try #require(
                try await server.windowLinks().first { $0.windowID == window.id }
            )

            // From a named preset, not from whatever the split produced: tmux
            // cycles a fixed list of layouts, and a custom arrangement is not
            // on it — so next-then-previous from one lands on the last preset
            // rather than back where it started.
            try await server.selectLayout(window, "even-horizontal")
            let start = try await server.format("#{window_layout}", for: link)

            try await server.nextLayout(window)
            let moved = try await server.format("#{window_layout}", for: link)
            #expect(moved != start, "next-layout left the layout where it was")

            try await server.previousLayout(window)
            let back = try await server.format("#{window_layout}", for: link)
            #expect(back == start, "previous-layout did not undo next-layout")
        }
    }
}

@Suite("pane geometry and replacement", .timeLimit(.minutes(5)))
struct PaneGeometryTests {
    @Test("a lone pane is against all four edges")
    func lonePaneIsAgainstEveryEdge() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "lone")
            let window = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let pane = try #require(
                try await server.snapshot().panes(of: window).first
            )
            #expect(pane.isAtTop)
            #expect(pane.isAtBottom)
            #expect(pane.isAtLeft)
            #expect(pane.isAtRight)
        }
    }

    @Test("a horizontal split puts one pane left and one right")
    func horizontalSplitSeparatesLeftFromRight() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "sides")
            let window = try #require(
                try await server.snapshot().windows(of: session).first
            )
            _ = try await server.splitWindow(window, direction: .right)

            let panes = try await server.snapshot().panes(of: window)
            #expect(panes.count == 2)
            // Both still span the full height; only the sides differ.
            let spanTop = panes.allSatisfy(\.isAtTop)
            let spanBottom = panes.allSatisfy(\.isAtBottom)
            #expect(spanTop)
            #expect(spanBottom)
            #expect(panes.filter(\.isAtLeft).count == 1)
            #expect(panes.filter(\.isAtRight).count == 1)
        }
    }

    @Test("a vertical split puts one pane above and one below")
    func verticalSplitSeparatesTopFromBottom() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "stack")
            let window = try #require(
                try await server.snapshot().windows(of: session).first
            )
            _ = try await server.splitWindow(window, direction: .below)

            let panes = try await server.snapshot().panes(of: window)
            let spanLeft = panes.allSatisfy(\.isAtLeft)
            let spanRight = panes.allSatisfy(\.isAtRight)
            #expect(spanLeft)
            #expect(spanRight)
            #expect(panes.filter(\.isAtTop).count == 1)
            #expect(panes.filter(\.isAtBottom).count == 1)
        }
    }

    @Test("respawning replaces what a pane runs")
    func respawningReplacesWhatAPaneRuns() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "respawn")
            let window = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let pane = try #require(
                try await server.snapshot().panes(of: window).first
            )

            try await server.respawn(pane, running: ["sleep", "43"])

            var command = ""
            for _ in 0..<200 {
                command =
                    try await server.snapshot().panes
                    .first { $0.id == pane.id }?.currentCommand ?? ""
                if command == "sleep" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(command == "sleep")
        }
    }

    @Test("a window option is set and read on that window alone")
    func windowOptionAppliesToOneWindow() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "options")
            let first = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let second = try await server.newWindow(in: session).window

            _ = try await server.setOption("@marked", to: "yes", scope: .window(first))
            let onFirst = try await server.option("@marked", scope: .window(first))
            let onSecond = try await server.option("@marked", scope: .window(second))
            #expect(onFirst == "yes")
            #expect(onSecond == nil)
        }
    }

    @Test("rotating moves panes between positions and keeps their identities")
    func rotatingMovesPanesNotIdentities() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "rotate")
            let window = try #require(
                try await server.snapshot().windows(of: session).first
            )
            _ = try await server.splitWindow(window)
            _ = try await server.splitWindow(window)

            func order() async throws -> [PaneID] {
                try await server.snapshot().panes(of: window).map(\.id)
            }

            let start = try await order()
            #expect(start.count == 3)

            try await server.rotate(window)
            let up = try await order()
            #expect(up == Array(start.dropFirst()) + [start[0]])

            try await server.rotate(window, upward: false)
            #expect(try await order() == start)
        }
    }

    @Test("last-pane returns to the pane that was active before")
    func lastPaneReturnsToThePriorPane() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "lastpane")
            let window = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let first = try #require(
                try await server.snapshot().panes(of: window).first
            )
            let second = try await server.splitWindow(window)

            func active() async throws -> PaneID? {
                try await server.snapshot().panes(of: window).first { $0.isActive }?.id
            }

            try await server.select(second)
            try await server.select(first)
            #expect(try await active() == first.id)

            try await server.selectLastPane(in: window)
            #expect(try await active() == second.id)
        }
    }

    @Test("a buffer round-trips through a file")
    func bufferRoundTripsThroughAFile() async throws {
        try await withTmuxServer { server in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("libtmux-buffer-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: directory) }

            let source = directory.appendingPathComponent("in")
            let destination = directory.appendingPathComponent("out")
            let contents = "first line\nsecond line\n"
            try contents.write(to: source, atomically: true, encoding: .utf8)

            try await server.loadBuffer(from: source.path, named: "carried")
            #expect(try await server.buffer(named: "carried") == "first line\nsecond line")

            try await server.saveBuffer(named: "carried", to: destination.path)
            #expect(try String(contentsOf: destination, encoding: .utf8) == contents)
        }
    }
}
