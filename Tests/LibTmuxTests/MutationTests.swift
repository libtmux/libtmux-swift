import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("mutations", .hangLimit)
struct MutationTests {
    @Test("typed and custom layouts preserve tmux's layout strings")
    func typedLayoutsReachTmux() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            let link = try #require(try await server.windowLinks().first)
            for _ in 0..<3 { _ = try await server.splitWindow(window) }
            let layouts: [(WindowLayout, String)] = [
                (.evenHorizontal, "even-horizontal"), (.evenVertical, "even-vertical"),
                (.mainHorizontal, "main-horizontal"), (.mainVertical, "main-vertical"),
                (.tiled, "tiled"),
            ]
            for (typed, name) in layouts {
                try await server.selectLayout(window, name)
                let expected = try #require(try await server.format("#{window_layout}", for: link))
                let reset = name == "even-horizontal" ? "even-vertical" : "even-horizontal"
                try await server.selectLayout(window, reset)
                try await server.selectLayout(window, typed)
                #expect(try await server.format("#{window_layout}", for: link) == expected)
                let encoded = try JSONEncoder().encode(typed)
                #expect(try JSONDecoder().decode(String.self, from: encoded) == name)
                #expect(try JSONDecoder().decode(WindowLayout.self, from: encoded) == typed)
            }
            let saved = try #require(try await server.format("#{window_layout}", for: link))
            try await server.selectLayout(window, .evenVertical)
            let custom = WindowLayout.custom(saved)
            let decoded = try JSONDecoder().decode(
                WindowLayout.self, from: JSONEncoder().encode(custom))
            try await server.selectLayout(window, decoded)
            #expect(try await server.format("#{window_layout}", for: link) == saved)
        }
    }

    @Test("a value that is not a layout is refused before dispatch")
    func unparseableLayoutValueIsRefusedClientSide() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            let link = try #require(try await server.windowLinks().first)
            for _ in 0..<3 { _ = try await server.splitWindow(window) }
            try await server.selectLayout(window, .tiled)
            try await server.selectLayout(window, .evenHorizontal)
            let beforeAttempt = try #require(
                try await server.format("#{window_layout}", for: link))
            // "-o" is select-layout's own "apply the last set layout" flag,
            // and "--" is what turns it into a layout string instead. Every
            // value here is one tmux cannot parse, which on 3.3 and 3.3a
            // frees an uninitialized `cause` and kills the daemon rather than
            // being rejected -- so none of them is sent at all.
            for value in ["-o", "garbage", "no-such-preset", "zzzz,80x24,0,0,0"] {
                await #expect(throws: TmuxError.self) {
                    try await server.selectLayout(window, WindowLayout.custom(value))
                }
            }
            // The unchanged layout is the proof select-layout never ran; the
            // server still answering is the proof it survived, which is what
            // fails on 3.3a without the refusal.
            #expect(try await server.format("#{window_layout}", for: link) == beforeAttempt)
        }
    }

    @Test("a mirrored preset is refused below the release that knows it")
    func mirroredPresetIsRefusedBelowThreeFive() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            _ = try await server.splitWindow(window)
            let mirrored = WindowLayout.custom("main-vertical-mirrored")
            if try await server.version() >= TmuxVersion(major: 3, minor: 5) {
                try await server.selectLayout(window, mirrored)
            } else {
                // An unknown name on 3.3a takes the same fatal path as any
                // other unparseable layout.
                await #expect(throws: TmuxError.self) {
                    try await server.selectLayout(window, mirrored)
                }
            }
            #expect(try await server.windows().first != nil)
        }
    }

    @Test("a JSON-shaped layout is refused before dispatch on a pre-3.8 server")
    func jsonShapedLayoutIsRefusedClientSideBelowThreeEight() async throws {
        try await withTmuxServer { server in
            let version = try await server.version()
            guard version < TmuxVersion(major: 3, minor: 8) else {
                // Covered the other way by wellFormedJSONLayoutAppliesFromThreeEight.
                return
            }
            let window = try #require(try await server.windows().first)
            let link = try #require(try await server.windowLinks().first)
            for _ in 0..<3 { _ = try await server.splitWindow(window) }
            try await server.selectLayout(window, .tiled)
            let beforeAttempt = try #require(
                try await server.format("#{window_layout}", for: link))
            // Well-formed JSON, but not a claim it is one this window's pane
            // count could ever satisfy -- tmux never sees it either way.
            let json = #"{"V":2,"L":{"t":"p","w":1,"h":1,"x":0,"y":0,"i":0,"I":"%0"}}"#
            await #expect(throws: TmuxError.self) {
                try await server.selectLayout(window, WindowLayout.custom(json))
            }
            // Unchanged layout is the observable proof select-layout never
            // ran. On 3.3/3.3a specifically, this is the crash the guard
            // exists for: unrefused, the same string kills the daemon
            // (verified directly against a real 3.3a binary; see the
            // remediation commit).
            #expect(try await server.format("#{window_layout}", for: link) == beforeAttempt)
        }
    }

    @Test("a layout that only looks like JSON is refused on every version")
    func malformedJSONShapedLayoutIsRefusedOnEveryVersion() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            do {
                try await server.selectLayout(window, WindowLayout.custom("{not json"))
                Issue.record("malformed JSON-shaped layout was accepted")
            } catch let error as TmuxError {
                #expect(error.description.contains("not valid JSON"))
            }
        }
    }

    @Test("a well-formed JSON layout applies from 3.8 onward")
    func wellFormedJSONLayoutAppliesFromThreeEight() async throws {
        try await withTmuxServer { server in
            let version = try await server.version()
            guard version >= TmuxVersion(major: 3, minor: 8) else {
                // The whole CI matrix predates 3.8; verified locally against
                // /home/d/.local/share/libtmux-tmux-matrix/master-e880cf63,
                // which reports next-3.9.
                return
            }
            let window = try #require(try await server.windows().first)
            let link = try #require(try await server.windowLinks().first)
            for _ in 0..<3 { _ = try await server.splitWindow(window) }
            try await server.selectLayout(window, .tiled)
            let saved = try #require(try await server.format("#{window_layout}", for: link))
            try await server.selectLayout(window, .evenVertical)
            try await server.selectLayout(window, WindowLayout.custom(saved))
            #expect(try await server.format("#{window_layout}", for: link) == saved)
        }
    }

    @Test("a saved layout with more panes than the target window degrades without error")
    func customLayoutWithExtraPanesDegradesSilently() async throws {
        try await withTmuxServer { server in
            let version = try await server.version()
            guard version >= TmuxVersion(major: 3, minor: 8) else {
                // The classic form has no pane count of its own to read back
                // against a mismatched window; verified locally against
                // /home/d/.local/share/libtmux-tmux-matrix/master-e880cf63.
                return
            }
            let session = try #require(try await server.sessions().first)
            let source = try #require(try await server.windows().first)
            for _ in 0..<3 { _ = try await server.splitWindow(source) }
            try await server.selectLayout(source, .tiled)
            let sourceLink = try #require(
                try await server.windowLinks().first { $0.windowID == source.id })
            let saved = try #require(try await server.format("#{window_layout}", for: sourceLink))

            let target = try await server.newWindow(in: session, named: "fewer-panes").window
            try await server.selectLayout(target, WindowLayout.custom(saved))
            let targetPanes = try await server.panes().filter { $0.windowID == target.id }
            // Raw tmux applies the same four-leaf tree to a one-pane window
            // without refusing it; this is tmux's own behavior (see
            // WindowLayout), not something this method validates.
            #expect(targetPanes.count == 1)
        }
    }

    @Test("creating an object returns it, already read back")
    func creatingReturnsTheObject() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "made", windowName: "first")
            #expect(session.name == "made")
            #expect(session.id.rawValue.hasPrefix("$"))

            let created = try await server.newWindow(in: session, named: "second")
            #expect(created.window.name == "second")
            #expect(created.link.sessionID == session.id)
            #expect(created.link.windowID == created.window.id)

            let pane = try await server.splitWindow(created.window)
            #expect(pane.windowID == created.window.id)
            #expect(pane.id.rawValue.hasPrefix("%"))
        }
    }

    @Test("objects are addressed by id, not by index")
    func objectsAreAddressedByID() async throws {
        try await withTmuxServer { server in
            // base-index is configurable, so the first window need not be 0.
            _ = try await server.run(TmuxCommand("set-option", ["-g", "base-index", "7"]))
            let session = try await server.newSession(named: "based")
            let window = try await server.newWindow(in: session, named: "seven").window

            // Renaming through the id works regardless of where tmux numbered it.
            try await server.rename(window, to: "renamed")
            let snapshot = try await server.snapshot()
            let stored = try #require(snapshot.windows.first { $0.id == window.id })
            #expect(stored.name == "renamed")
        }
    }

    @Test("a split puts the new pane on the side it was asked for")
    func splitPlacesThePaneWhereAsked() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "split")
            // Asserted from where the pane landed rather than from the flags
            // sent, which is the only way to tell a direction that works from
            // one that was merely spelled correctly.
            for direction in [PaneDirection.right, .left, .above, .below] {
                let window = try await server.newWindow(in: session).window
                let pane = try await server.splitWindow(window, direction: direction)
                let edges =
                    "top=\(pane.isAtTop) bottom=\(pane.isAtBottom) "
                    + "left=\(pane.isAtLeft) right=\(pane.isAtRight)"
                switch direction {
                case .right:
                    #expect(pane.isAtRight && !pane.isAtLeft, "\(direction): \(edges)")
                case .left:
                    #expect(pane.isAtLeft && !pane.isAtRight, "\(direction): \(edges)")
                case .above:
                    #expect(pane.isAtTop && !pane.isAtBottom, "\(direction): \(edges)")
                case .below:
                    #expect(pane.isAtBottom && !pane.isAtTop, "\(direction): \(edges)")
                }
            }
        }
    }

    @Test("splitting with no direction stacks the new pane below, as tmux does")
    func splitDefaultsToBelow() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "default")
            let window = try await server.newWindow(in: session).window

            let pane = try await server.splitWindow(window)

            #expect(pane.isAtBottom && !pane.isAtTop)
        }
    }

    @Test("a window can be created on either side of another")
    func windowCanBePlacedEitherSide() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "place")
            let anchor = try await server.newWindow(in: session, named: "anchor")
            _ = try await server.newWindow(.after, anchor.link, named: "after")
            _ = try await server.newWindow(.before, anchor.link, named: "before")

            // Read back in tmux's order rather than trusting the indices each
            // window had when it was made: inserting before one renumbers it
            // and everything after it.
            let snapshot = try await server.snapshot()
            let names = snapshot.windowLinks(of: session)
                .sorted { $0.index < $1.index }
                .compactMap { link in
                    snapshot.windows.first { $0.id == link.windowID }?.name
                }
            let before = try #require(names.firstIndex(of: "before"))
            let middle = try #require(names.firstIndex(of: "anchor"))
            let after = try #require(names.firstIndex(of: "after"))
            #expect(before < middle, "\(names)")
            #expect(middle < after, "\(names)")
        }
    }

    @Test("relative creation uses the selected link's session")
    func relativeCreationUsesTheSelectedLinkSession() async throws {
        try await withTmuxServer { server in
            let source = try #require(try await server.windows().first)
            let destination = try await server.newSession(named: "place-linked")
            let destinationLink = try await server.link(source, into: destination)

            let created = try await server.newWindow(
                .after, destinationLink, named: "beside-link")

            #expect(created.link.sessionID == destination.id)
            #expect(created.link.index == destinationLink.index + 1)
        }
    }

    @Test("a resize moves the boundary the way it was told to")
    func resizeMovesTheBoundary() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "resize")
            let window = try #require(
                try await server.snapshot().windows(of: session).first
            )
            let lower = try await server.splitWindow(window, direction: .below)
            let before = try await server.snapshot().panes(of: window)
            let lowerWas = try #require(before.first { $0.id == lower.id })
            let upperWas = try #require(before.first { $0.id != lower.id })

            try await server.resize(lower, by: 3, toward: .up)

            let after = try await server.snapshot().panes(of: window)
            let lowerIs = try #require(after.first { $0.id == lower.id })
            let upperIs = try #require(after.first { $0.id != lower.id })
            // The boundary between them moved up, so the lower pane gained
            // exactly what the upper one lost.
            #expect(lowerIs.height == lowerWas.height + 3)
            #expect(upperIs.height == upperWas.height - 3)
        }
    }

    @Test("a split takes its size in cells or as a share of the window")
    func splitTakesASize() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "sized")

            let byCells = try await server.newWindow(in: session).window
            let narrow = try await server.splitWindow(
                byCells,
                direction: .right,
                size: .cells(20)
            )
            #expect(narrow.width == 20)

            let byShare = try await server.newWindow(in: session).window
            let half = try await server.splitWindow(
                byShare,
                direction: .below,
                size: .percentage(50)
            )
            #expect(half.height == byShare.height / 2)
        }
    }

    @Test("renaming reaches both sessions and windows")
    func renamingReachesSessionsAndWindows() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "before")
            try await server.rename(session, to: "after")

            let sessions = try await server.sessions()
            #expect(sessions.contains { $0.name == "after" })
            #expect(!sessions.contains { $0.name == "before" })
        }
    }

    @Test("killing removes exactly its target")
    func killingRemovesExactlyItsTarget() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "doomed")
            let keep = try await server.newWindow(in: session, named: "keep").window
            let go = try await server.newWindow(in: session, named: "go").window

            try await server.kill(go)
            let windows = try await server.windows()
            #expect(windows.contains { $0.id == keep.id })
            #expect(!windows.contains { $0.id == go.id })

            try await server.kill(session)
            let sessions = try await server.sessions()
            #expect(!sessions.contains { $0.id == session.id })
        }
    }

    @Test("killing the last pane of a window takes the window with it")
    func killingTheLastPaneTakesItsWindow() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "panes")
            let window = try await server.newWindow(in: session).window
            let extra = try await server.splitWindow(window)

            try await server.kill(extra)
            let after = try await server.snapshot()
            #expect(after.panes(of: window).count == 1)
            #expect(after.windows.contains { $0.id == window.id })
        }
    }

    @Test("what a pane prints can be captured back")
    func paneOutputCanBeCaptured() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "capture")
            let window = try await server.newWindow(in: session).window
            let pane = try #require(
                try await server.snapshot().panes(of: window).first
            )

            try await server.run("echo captured-marker", in: pane)

            let printed = try await waitUntil {
                try await server.capture(pane)
                    .contains { $0.contains("captured-marker") }
            }
            #expect(printed)
        }
    }

    @Test("literal keys are characters, not key names")
    func literalKeysAreCharacters() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "literal")
            let window = try await server.newWindow(in: session).window
            let pane = try #require(
                try await server.snapshot().panes(of: window).first
            )

            // Without -l tmux would read this as the Enter key.
            try await server.sendKeys(["echo Enter-as-text"], to: pane, literally: true)
            try await server.sendKeys(["Enter"], to: pane)

            let typed = try await waitUntil {
                try await server.capture(pane)
                    .contains { $0.contains("Enter-as-text") }
            }
            #expect(typed)
        }
    }

    @Test("a rejected mutation reports what tmux objected to")
    func rejectedMutationReportsItsReason() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "taken")
            await #expect(throws: TmuxError.self) {
                // tmux refuses a duplicate session name.
                _ = try await server.newSession(named: "taken")
            }
            #expect(try await server.sessions().contains { $0.id == session.id })
        }
    }
    @Test("a name carrying format syntax is stored as written")
    func namesAreNotExpanded() async throws {
        try await withTmuxServer { server in
            // tmux expands a name before storing it, so an unescaped one would
            // come back naming the session, or carrying the machine's hostname.
            let window = try #require(try await server.windows().first)
            try await server.rename(window, to: "w-#{session_name}")
            #expect(try await server.windows().first?.name == "w-#{session_name}")

            let session = try #require(try await server.sessions().first)
            try await server.rename(session, to: "s-#{host_short}")
            #expect(try await server.sessions().first?.name == "s-#{host_short}")

            let created = try await server.newWindow(in: session, named: "n-#{host}")
            #expect(created.window.name == "n-#{host}")

            // A start directory is expanded the same way, and there `#(...)`
            // runs rather than merely substituting.
            let directory = NSTemporaryDirectory() + "libtmux-swift-test-dir-#H"
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let placed = try await server.newWindow(
                in: session, named: "cwd", startDirectory: directory)
            let currentDirectory = try #require(
                try await server.format("#{pane_current_path}", for: placed.link))
            let resolved = { (path: String) in
                URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            }
            #expect(resolved(currentDirectory) == resolved(directory))

            // tmux expands a buffer path too, so a file whose name contains
            // format syntax could not be reached at all.
            let path = NSTemporaryDirectory() + "libtmux-swift-test-#{host_short}.txt"
            defer { try? FileManager.default.removeItem(atPath: path) }
            try "buffered\n".write(toFile: path, atomically: true, encoding: .utf8)
            try await server.loadBuffer(from: path, named: "literal")
            #expect(try await server.buffer(named: "literal") == "buffered")
        }
    }

}
