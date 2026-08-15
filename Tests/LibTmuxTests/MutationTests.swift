import Testing
import TmuxFixture

@testable import LibTmux

@Suite("mutations", .timeLimit(.minutes(1)))
struct MutationTests {
    @Test("creating an object returns it, already read back")
    func creatingReturnsTheObject() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "made", windowName: "first")
            #expect(session.name == "made")
            #expect(session.id.hasPrefix("$"))

            let window = try await server.newWindow(in: session, named: "second")
            #expect(window.name == "second")
            #expect(window.sessionID == session.id)

            let pane = try await server.splitWindow(window)
            #expect(pane.windowID == window.id)
            #expect(pane.id.hasPrefix("%"))
        }
    }

    @Test("objects are addressed by id, not by index")
    func objectsAreAddressedByID() async throws {
        try await withTmuxServer { server in
            // base-index is configurable, so the first window need not be 0.
            _ = try await server.run(TmuxCommand("set-option", ["-g", "base-index", "7"]))
            let session = try await server.newSession(named: "based")
            let window = try await server.newWindow(in: session, named: "seven")

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
                let window = try await server.newWindow(in: session)
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
            let window = try await server.newWindow(in: session)

            let pane = try await server.splitWindow(window)

            #expect(pane.isAtBottom && !pane.isAtTop)
        }
    }

    @Test("a window can be created on either side of another")
    func windowCanBePlacedEitherSide() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "place")
            let anchor = try await server.newWindow(in: session, named: "anchor")
            _ = try await server.newWindow(.after, anchor, named: "after")
            _ = try await server.newWindow(.before, anchor, named: "before")

            // Read back in tmux's order rather than trusting the indices each
            // window had when it was made: inserting before one renumbers it
            // and everything after it.
            let names = try await server.windows()
                .filter { $0.sessionID == session.id }
                .sorted { $0.index < $1.index }
                .map(\.name)
            let before = try #require(names.firstIndex(of: "before"))
            let middle = try #require(names.firstIndex(of: "anchor"))
            let after = try #require(names.firstIndex(of: "after"))
            #expect(before < middle, "\(names)")
            #expect(middle < after, "\(names)")
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

            let byCells = try await server.newWindow(in: session)
            let narrow = try await server.splitWindow(
                byCells,
                direction: .right,
                size: .cells(20)
            )
            #expect(narrow.width == 20)

            let byShare = try await server.newWindow(in: session)
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
            let keep = try await server.newWindow(in: session, named: "keep")
            let go = try await server.newWindow(in: session, named: "go")

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
            let window = try await server.newWindow(in: session)
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
            let window = try await server.newWindow(in: session)
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
            let window = try await server.newWindow(in: session)
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
}
