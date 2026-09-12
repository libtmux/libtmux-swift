import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

/// A lookup must answer exactly what searching a full listing would.
///
/// It reaches tmux by a different route — a narrowed listing rather than a
/// whole one — so the tests compare the two routes rather than asserting a
/// hand-written expectation, the same way the filter lowering is tested.
@Suite("lookup", .timeLimit(.minutes(2)))
struct LookupTests {
    @Test("looking one object up matches searching the whole listing")
    func lookupAgreesWithListing() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "look")
            let appearance = try await server.newWindow(in: session, named: "target")
            let pane = try await server.splitWindow(appearance.window)

            // A value is what the server looked like when it was read, and
            // both of these have since changed — the session gained a window,
            // the window gained a pane. So the contract is that a lookup equals
            // what searching a listing taken NOW would find, not what the value
            // in hand still says.
            let listedSession = try await server.sessions().first { $0.id == session.id }
            let listedWindow = try await server.windows().first { $0.id == appearance.window.id }
            let listedPane = try await server.panes().first { $0.id == pane.id }

            let byID = try await server.session(session.id)
            let byName = try await server.session(named: "look")
            let window = try await server.window(appearance.window.id)
            let lookedUpPane = try await server.pane(pane.id)

            #expect(byID == listedSession)
            #expect(byName == listedSession)
            #expect(window == listedWindow)
            #expect(lookedUpPane == listedPane)
            // ...and it is still the object that was created.
            #expect(byID?.id == session.id)
            #expect(window?.name == "target")
        }
    }

    @Test("an object that is not there is nil, not an error")
    func absenceIsNil() async throws {
        try await withTmuxServer { server in
            let noSession = try await server.session("$999")
            let noWindow = try await server.window("@999")
            let noPane = try await server.pane("%999")
            let noNamed = try await server.session(named: "never-created")
            let noWindows = try await server.windows(named: "never-created")
            #expect(noSession == nil)
            #expect(noWindow == nil)
            #expect(noPane == nil)
            #expect(noNamed == nil)
            #expect(noWindows.isEmpty)
        }
    }

    @Test("a name tmux reads as format syntax still looks up exactly")
    func hostileNamesLookUp() async throws {
        try await withTmuxServer { server in
            // tmux renames a window it did not get an explicit name for as the
            // command inside it changes, so the bootstrap window drifts from
            // "tmux" to whatever shell settles. These cases read the names once
            // and then compare two listings against them, which that rename
            // loses a race with. Each case has its own server, so turning it off
            // here is scoped to this one.
            _ = try await server.setOption("automatic-rename", to: "off")
            let session = try await server.newSession(named: "hostile")
            for name in ["with,comma", "with}brace", "glob*star", "with#hash"] {
                _ = try await server.newWindow(in: session, named: name)
            }
            for window in try await server.windows() where window.name != "bootstrap" {
                let found = try await server.windows(named: window.name)
                #expect(
                    found.contains(window),
                    "looking up \(window.name.debugDescription) did not find it"
                )
            }
        }
    }

    @Test("refreshing sees a change made since the value was read")
    func refreshSeesChanges() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "before")
            let window = try await server.newWindow(in: session, named: "first").window

            try await server.rename(session, to: "after")
            try await server.rename(window, to: "second")

            let freshSession = try await server.refresh(session)
            let freshWindow = try await server.refresh(window)
            #expect(freshSession?.name == "after")
            #expect(freshWindow?.name == "second")
        }
    }

    @Test("refreshing something that has been killed is nil")
    func refreshAfterKillIsNil() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "doomed")
            let window = try await server.newWindow(in: session, named: "alive").window
            try await server.kill(window)
            let gone = try await server.refresh(window)
            #expect(gone == nil)
        }
    }

    @Test("a value from another server cannot be refreshed against this one")
    func foreignValuesAreRefused() async throws {
        try await withTmuxServer(socketFileName: "one") { first in
            try await withTmuxServer(socketFileName: "two") { second in
                let session = try await first.newSession(named: "mine")
                // ids restart at zero on a new daemon, so without the guard this
                // would happily return a different server's session.
                await #expect(throws: TmuxError.foreignServerValue) {
                    _ = try await second.refresh(session)
                }
            }
        }
    }
}
