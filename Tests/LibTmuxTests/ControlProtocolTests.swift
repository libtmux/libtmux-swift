import Testing

@testable import LibTmux

/// Captured verbatim from `tmux -C attach-session` on 3.7b, driven with
/// `list-sessions`, `display-message`, an unknown command, and `kill-server`.
private let capturedStream = """
    %begin 1786717675 347 0
    %end 1786717675 347 0
    %session-changed $0 boot
    %begin 1786717675 352 1
    boot
    %end 1786717675 352 1
    %begin 1786717675 353 1
    ok
    %end 1786717675 353 1
    %begin 1786717675 354 1
    parse error: unknown command: no-such-command
    %error 1786717675 354 1
    %begin 1786717675 355 1
    %end 1786717675 355 1
    %sessions-changed
    %exit
    """

private func parse(_ stream: String) -> [ControlEvent] {
    var parser = ControlProtocolParser()
    return stream.split(separator: "\n", omittingEmptySubsequences: false)
        .compactMap { parser.consume(String($0)) }
}

@Suite("control-mode protocol")
struct ControlProtocolTests {
    @Test("a captured session parses into its replies, notifications, and exit")
    func capturedSessionParses() {
        let events = parse(capturedStream)
        #expect(events.count == 8)

        guard case let .reply(attach) = events[0] else {
            Issue.record("expected the attach reply first")
            return
        }
        #expect(attach.number == 347)
        #expect(attach.lines.isEmpty)
        #expect(!attach.isError)

        guard case let .notification(changed) = events[1] else {
            Issue.record("expected a notification between blocks")
            return
        }
        #expect(changed.name == "session-changed")
        #expect(changed.arguments == "$0 boot")

        #expect(events.last == .exited)
    }

    @Test("each reply carries the number of the command it answers")
    func repliesCarryTheirCommandNumber() {
        let replies = parse(capturedStream).compactMap { event -> ControlReply? in
            guard case let .reply(reply) = event else { return nil }
            return reply
        }
        // Attribution is the whole point: a `;` list merges output, this does
        // not.
        #expect(replies.map(\.number) == [347, 352, 353, 354, 355])
        #expect(replies[1].lines == ["boot"])
        #expect(replies[2].lines == ["ok"])
    }

    @Test("an error block reports its reason where output would be")
    func errorBlockReportsItsReason() {
        let replies = parse(capturedStream).compactMap { event -> ControlReply? in
            guard case let .reply(reply) = event else { return nil }
            return reply
        }
        let failed = replies[3]
        #expect(failed.isError)
        #expect(failed.lines == ["parse error: unknown command: no-such-command"])

        #expect(replies.filter(\.isError).count == 1)
    }

    @Test("a command that produced no output is an empty reply, not a missing one")
    func silentCommandIsAnEmptyReply() {
        let replies = parse(capturedStream).compactMap { event -> ControlReply? in
            guard case let .reply(reply) = event else { return nil }
            return reply
        }
        #expect(replies.last?.number == 355)
        #expect(replies.last?.lines.isEmpty == true)
        #expect(replies.last?.isError == false)
    }

    @Test("output that looks like a notification stays inside its block")
    func outputResemblingANotificationStaysInItsBlock() {
        // A pane can print anything, including a line starting with `%`. Inside
        // a block that is output; treating it as a notification would truncate
        // the reply and invent an event.
        let events = parse(
            """
            %begin 1 1 1
            %output %0 not really a notification
            plain
            %end 1 1 1
            """
        )
        #expect(events.count == 1)
        guard case let .reply(reply) = events[0] else {
            Issue.record("expected one reply")
            return
        }
        #expect(reply.lines == ["%output %0 not really a notification", "plain"])
    }

    @Test("a notification outside a block is an event")
    func notificationOutsideABlockIsAnEvent() {
        let events = parse("%output %0 hello\n%window-add @2")
        #expect(events.count == 2)
        guard case let .notification(output) = events[0],
            case let .notification(added) = events[1]
        else {
            Issue.record("expected two notifications")
            return
        }
        #expect(output.name == "output")
        #expect(output.arguments == "%0 hello")
        #expect(added.name == "window-add")
        #expect(added.arguments == "@2")
    }

    @Test("the parser reports whether a reply is still open")
    func parserReportsAnOpenBlock() {
        var parser = ControlProtocolParser()
        #expect(!parser.isInsideBlock)
        _ = parser.consume("%begin 1 9 1")
        #expect(parser.isInsideBlock)
        _ = parser.consume("%end 1 9 1")
        #expect(!parser.isInsideBlock)
    }
}
