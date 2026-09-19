import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("control notification events", .hangLimit)
struct ControlNotificationEventTests {
    private func event(_ name: String, _ arguments: String) -> ControlNotification.Event {
        ControlNotification(name: name, arguments: arguments).event
    }

    @Test("output undoes tmux's octal escaping, and a backslash always starts one")
    func outputUndoesOctalEscaping() {
        // tmux writes bytes below a space and every backslash as \ooo.
        let decoded = event("output", "%3 ab\\015\\012c\\134d é")
        #expect(
            decoded
                == .output(
                    pane: "%3",
                    bytes: Array("ab\r\nc\\d é".utf8)
                ))
    }

    @Test("output data may itself contain spaces")
    func outputKeepsItsSpaces() {
        #expect(event("output", "%0 a b  c") == .output(pane: "%0", bytes: Array("a b  c".utf8)))
    }

    @Test("extended output carries its age in milliseconds")
    func extendedOutputCarriesItsAge() {
        #expect(
            event("extended-output", "%2 1500 : hi\\012")
                == .extendedOutput(pane: "%2", ageMilliseconds: 1500, bytes: Array("hi\n".utf8)))
    }

    @Test("identifier-bearing notifications decode to typed ids")
    func identifierNotificationsDecode() {
        #expect(event("window-add", "@4") == .windowAdded("@4"))
        #expect(event("pause", "%1") == .paused(pane: "%1"))
        #expect(event("continue", "%1") == .continued(pane: "%1"))
        #expect(event("session-changed", "$2 my work") == .sessionChanged("$2", name: "my work"))
        #expect(event("window-pane-changed", "@1 %5") == .windowPaneChanged("@1", pane: "%5"))
        #expect(event("sessions-changed", "") == .sessionsChanged)
    }

    @Test("a format this library does not read arrives intact rather than lost")
    func unknownFormatsArriveIntact() {
        let raw = ControlNotification(name: "some-future-thing", arguments: "x y")
        #expect(raw.event == .unrecognized(raw))
        // A known name with an argument it cannot read is not guessed at.
        let malformed = ControlNotification(name: "window-add", arguments: "not-an-id")
        #expect(malformed.event == .unrecognized(malformed))
    }

    @Test("the decoder reads what tmux actually sends")
    func decoderMatchesLiveTmux() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "events")
            // Control mode reports output only for the session it is attached
            // to, so the pane has to be this session's -- not the fixture's.
            let target = try #require(
                try await server.snapshot().panes(of: session).first)
            let bytes = try await server.connected(attachingTo: session) { server, control in
                try await server.send(
                    [.text("printf 'X\\tY\\\\Z\\n'"), .key("Enter")], to: target)
                var seen = 0
                var received: [UInt8] = []
                for try await notification in control.notifications {
                    seen += 1
                    // Output arrives in pieces, and the shell's echo of the
                    // typed command comes first. Only printf's output holds a
                    // real tab -- the echo holds a backslash and a `t`.
                    if case let .output(pane, data) = notification.event, pane == target.id {
                        received += data
                        if received.contains(0x09) { return received }
                    }
                    // A loop with no way out holds the connection for as long
                    // as the server lives; this one gives up.
                    if seen > 500 { return [] }
                }
                return []
            }
            // A tab and a backslash, both of which tmux escaped on the wire.
            #expect(String(decoding: bytes, as: UTF8.self).contains("X\tY\\Z"))
        }
    }

    @Test("a connection can pause and resume a pane's output")
    func pauseAndResumeRoundTrip() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "flow")
            try await server.connected(attachingTo: session) { server, control in
                let target = try #require(try await server.panes().first)
                // Both are accepted by every supported release; a rejected
                // command throws rather than returning quietly.
                try await control.pauseOutput(of: target.id)
                try await control.resumeOutput(of: target.id)
                try await control.pauseOutput(after: .milliseconds(1500))
            }
        }
    }
}
