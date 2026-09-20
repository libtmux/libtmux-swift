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
            let release = "events-\(UUID().uuidString)"
            let bytes = try await server.connected(attachingTo: session) { server, control in
                let notifications = control.notifications
                return try await withThrowingTaskGroup(of: [UInt8].self) { group in
                    group.addTask {
                        // The suffix waits until the tab has arrived in a separate notification.
                        try await server.send(
                            [
                                .text(
                                    "printf 'X\\t'; \(server.shellInvocation) wait-for \(release); "
                                        + "printf 'Y\\\\Z\\n'"),
                                .key("Enter"),
                            ], to: target)
                        var released = false
                        var received: [UInt8] = []
                        for try await notification in notifications {
                            guard case let .output(pane, data) = notification.event,
                                pane == target.id
                            else { continue }
                            received += data
                            if received.contains(0x09), !released {
                                released = true
                                try await server.signal(release)
                            }
                            if String(decoding: received, as: UTF8.self).contains("X\tY\\Z") {
                                return received
                            }
                        }
                        return []
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(1))
                        return []
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? []
                }
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
