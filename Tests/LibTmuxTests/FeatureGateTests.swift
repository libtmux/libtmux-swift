import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

// MARK: - Which batch a release can run

@Suite("optional tmux features: command guards")
struct CommandGuardTests {
    private func check(_ release: String, _ arguments: [String]) throws(TmuxError) {
        try TmuxCommandGuard.check(arguments, against: Support.Versions.requireCore(release))
    }

    private func refused(_ release: String, _ arguments: [String]) -> Bool {
        do {
            try check(release, arguments)
            return false
        } catch {
            if case .unsupportedTmuxVersion = error { return true }
            return false
        }
    }

    @Test("exact named-buffer deletion and rename need 3.4")
    func namedBufferEditing() {
        for release in ["3.3a"] {
            #expect(refused(release, ["delete-buffer", "-b", "staged"]))
            #expect(refused(release, ["deleteb", "-bstaged"]))
            #expect(refused(release, ["set-buffer", "-b", "old", "-n", "new"]))
            #expect(refused(release, ["new-session", "-d", ";", "delete-buffer", "-b", "x"]))
            // Naming the buffer that is set, pasted or deleted-after-paste is exact on 3.3a.
            #expect(!refused(release, ["set-buffer", "-b", "staged", "--", "text"]))
            #expect(!refused(release, ["paste-buffer", "-d", "-b", "staged"]))
            #expect(!refused(release, ["delete-buffer"]))
        }
        for release in ["3.4", "3.5", "3.7d", "next-3.9"] {
            #expect(!refused(release, ["delete-buffer", "-b", "staged"]))
            #expect(!refused(release, ["set-buffer", "-b", "old", "-n", "new"]))
        }
    }

    @Test("tmux 3.7 crashes break-pane without a name and refuses '.' and ':' in names")
    func exactThreeSeven() {
        #expect(refused("3.7", ["break-pane", "-d", "-s", "%1"]))
        #expect(!refused("3.7", ["break-pane", "-d", "-s", "%1", "-n", "work"]))
        #expect(refused("3.7", ["break-pane", "-s", "%1", "-n", "a.b"]))
        #expect(refused("3.7", ["new-session", "-d", "-s", "a:b"]))
        #expect(refused("3.7", ["new-window", "-n", "x.y"]))
        #expect(refused("3.7", ["rename-window", "-t", "@1", "x:y"]))
        #expect(refused("3.7", ["rename-session", "a.b"]))
        #expect(!refused("3.7", ["new-session", "-d", "-s", "plain"]))
        for release in ["3.6b", "3.7a", "3.7d", "3.8", "next-3.9", "3.3a"] {
            #expect(
                !refused(release, ["break-pane", "-d", "-s", "%1"]), Comment(rawValue: release))
            #expect(
                !refused(release, ["new-session", "-d", "-s", "a.b"]), Comment(rawValue: release))
        }
    }

    @Test("split-window -p is broken on 3.4 only")
    func percentSplit() {
        #expect(refused("3.4", ["split-window", "-p", "30"]))
        #expect(refused("3.4", ["splitw", "-hp30"]))
        #expect(!refused("3.4", ["split-window", "-l", "30%"]))
        for release in ["3.3a", "3.5", "3.7d"] {
            #expect(!refused(release, ["split-window", "-p", "30"]), Comment(rawValue: release))
        }
    }

    @Test("below 3.4 only a layout tmux can parse is sent")
    func layoutsBelowThreeFour() {
        #expect(refused("3.3a", ["select-layout", "-t", "@1", "garbage"]))
        #expect(refused("3.3a", ["select-layout", "0000,80x24,0,0,0"]))
        #expect(!refused("3.3a", ["select-layout", "-t", "@1", "tiled"]))
        #expect(!refused("3.3a", ["select-layout", "-t", "@1", "even-h"]))
        #expect(!refused("3.3a", ["select-layout", "-n"]))
        #expect(!refused("3.4", ["select-layout", "-t", "@1", "garbage"]))
    }

    @Test("a command inside a shell string is the caller's own program")
    func shellStringsAreNotRead() {
        #expect(!refused("3.3a", ["if-shell", "-F", "1", "delete-buffer -b x"]))
        #expect(!refused("3.3a", ["run-shell", "tmux delete-buffer -b x"]))
    }
}

// MARK: - Against the lane's tmux

@Suite("optional tmux features: against the lane's tmux", .timeLimit(.minutes(5)))
struct FeatureLaneTests {
    @Test(
        "control attachment is refused below 3.7 before any client attaches",
        .enabled(if: laneIsSupported && !laneSupportsControl, "needs 3.3a to 3.6")
    )
    func controlRefusedBelowThreeSeven() async throws {
        try await withTmuxServer { server in
            await #expect(throws: TmuxError.self) {
                try await server.connected(attachingTo: "bootstrap") { _, _ in 0 }
            }
            await #expect(throws: TmuxError.self) {
                try await server.using(.connected(to: "bootstrap")) { _ in 0 }
            }
            let clients = try await server.clients()
            #expect(clients.allSatisfy { !$0.isControlMode })
            // The same server still serves subprocess work.
            let sessions = try await server.sessions()
            #expect(sessions.map(\.name) == ["bootstrap"])
        }
    }

    @Test(
        "control attachment works from 3.7",
        .enabled(if: laneSupportsControl, "needs 3.7 or newer")
    )
    func controlAllowedFromThreeSeven() async throws {
        try await withTmuxServer { server in
            let names = try await server.connected(attachingTo: "bootstrap") { server, _ in
                try await server.sessions().map(\.name)
            }
            #expect(names == ["bootstrap"])
        }
    }

    @Test(
        "waiting for output polls below 3.7 and attaches no control client",
        .enabled(if: laneIsSupported && !laneSupportsControl, "needs 3.3a to 3.6")
    )
    func waitPollsBelowThreeSeven() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("sleep 1; echo polled-marker-$((20+22))", in: pane)
            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("polled-marker-42")],
                timeout: .seconds(20))
            #expect(result.outcome == .matched)
            #expect(try await server.clients().allSatisfy { !$0.isControlMode })
        }
    }

    @Test(
        "named buffers cannot be deleted exactly below 3.4, and nothing is deleted",
        .enabled(if: laneIsSupported && !laneSupportsNamedBufferEditing, "needs 3.3a")
    )
    func bufferDeletionRefusedBelowThreeFour() async throws {
        try await withTmuxServer { server in
            try await server.setBuffer("keep", named: "keep-me")
            try await server.setBuffer("top", named: "newest")
            await #expect(throws: TmuxError.self) {
                try await server.deleteBuffer(named: "keep-me")
            }
            await #expect(throws: TmuxError.self) {
                try await server.deleteBuffer(named: "does-not-exist")
            }
            #expect(Set(try await server.buffers().map(\.name)) == ["keep-me", "newest"])
            #expect(try await server.buffer(named: "keep-me") == "keep")
        }
    }

    @Test(
        "named buffers are deleted exactly from 3.4",
        .enabled(if: laneSupportsNamedBufferEditing, "needs 3.4 or newer")
    )
    func bufferDeletionFromThreeFour() async throws {
        try await withTmuxServer { server in
            try await server.setBuffer("keep", named: "keep-me")
            try await server.setBuffer("top", named: "newest")
            try await server.deleteBuffer(named: "keep-me")
            #expect(try await server.buffers().map(\.name) == ["newest"])
        }
    }

    @Test(
        "a pane alone in its window breaks out and is read back on every supported release",
        .enabled(if: laneIsSupported, "needs a supported tmux")
    )
    func singlePaneBreakIsReread() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            let pane = try #require(try await server.panes().first { $0.windowID == window.id })
            let link = try #require(try await server.windowLinks().first)
            let appearance = try await server.breakPane(pane, from: link, named: "alone")
            #expect(appearance.window.id == window.id)
            #expect(appearance.window.paneCount == 1)
            #expect(appearance.window.name == "alone")
        }
    }

    @Test(
        "a layout tmux 3.3a would crash on is refused before it is sent",
        .enabled(if: laneIsSupported && !laneAtLeast(3, 4), "needs 3.3a")
    )
    func invalidLayoutNeverReachesThreeThreeA() async throws {
        try await withTmuxServer { server in
            let identity = try await server.incarnation()
            await #expect(throws: TmuxError.self) {
                _ = try await server.run(
                    TmuxCommand("select-layout", ["-t", "bootstrap", "not-a-layout"]))
            }
            // The daemon is still the one that was there.
            #expect(try await server.incarnation() == identity)
        }
    }
}
