import Testing

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("pane echo tracking")
struct PaneEchoTests {
    private func key(processID: Int = 42, pane: PaneID = "%1") throws -> PaneEchoes.Key {
        let endpoint = try Endpoint(socketPath: "/tmp/libtmux-swift-test/echo-unit")
        return PaneEchoes.Key(
            incarnation: ServerIncarnation(
                endpoint: endpoint, socketPath: "/tmp/libtmux-swift-test/echo-unit",
                processID: processID, startedAt: 7
            ),
            pane: pane
        )
    }

    @Test("unsubmitted text is discounted before dispatch finishes")
    func pendingDispatch() async throws {
        let echoes = PaneEchoes()
        let pane = try key()
        let update = await echoes.apply(.literal(["echo MARKER"], enter: false), to: [pane])
        let discount = await echoes.discount(for: pane, waitStart: .now)
        #expect(discount.transform("$ echo MARKER") == "$ ")
        #expect(discount.cursorRowUnsettled)
        await echoes.commit(update)
        #expect(await echoes.hasPending(pane))
    }

    @Test("a rejected dispatch restores the previous line and discounts")
    func failedDispatch() async throws {
        let echoes = PaneEchoes()
        let pane = try key()
        let first = await echoes.apply(.literal(["kept"], enter: false), to: [pane])
        await echoes.commit(first)
        let failed = await echoes.apply(.keys(["Enter", "rejected", "Enter"]), to: [pane])
        await echoes.abandon(failed)
        let discount = await echoes.discount(for: pane, waitStart: .now)
        #expect(discount.transform("rejected") == "rejected")
        #expect(discount.transform("kept") == "")
        #expect(discount.cursorRowUnsettled)
    }

    @Test("edits retain the earlier echo while the current line changes")
    func editedLine() async throws {
        let echoes = PaneEchoes()
        let pane = try key()
        await echoes.commit(await echoes.apply(.keys(["wordé"]), to: [pane]))
        await echoes.commit(await echoes.apply(.keys(["BSpace", "DC", "Enter"]), to: [pane]))
        let discount = await echoes.discount(for: pane, waitStart: .now)
        #expect(discount.transform("wordé / word") == " / ")
        #expect(!discount.cursorRowUnsettled)
        await echoes.commit(await echoes.apply(.keys(["cancelled", "C-u"]), to: [pane]))
        #expect(await echoes.discount(for: pane, waitStart: .now).transform("cancelled") == "")
        await echoes.commit(await echoes.apply(.keys(["xMARKER"]), to: [pane]))
        await echoes.commit(
            await echoes.apply(.keys(Array(repeating: "BSpace", count: 7)), to: [pane])
        )
        #expect(await echoes.discount(for: pane, waitStart: .now).transform("xMARKER") == "")
    }

    @Test("unknown keys stop tracking the current line")
    func unknownKey() async throws {
        let echoes = PaneEchoes()
        let pane = try key()
        await echoes.commit(await echoes.apply(.keys(["visible", "Left"]), to: [pane]))
        let discount = await echoes.discount(for: pane, waitStart: .now)
        #expect(discount.transform("visible") == "visible")
        #expect(!discount.cursorRowUnsettled)
    }

    @Test("oversized input fails open until a line reset")
    func oversizedLine() async throws {
        let echoes = PaneEchoes()
        let pane = try key()
        let oversized = String(repeating: "x", count: 1_048_577)
        await echoes.commit(await echoes.apply(.literal([oversized], enter: false), to: [pane]))
        #expect(!(await echoes.hasPending(pane)))
        await echoes.commit(await echoes.apply(.keys(["tail"]), to: [pane]))
        #expect(!(await echoes.hasPending(pane)))
        await echoes.commit(await echoes.apply(.keys(["C-u", "reset", "Enter"]), to: [pane]))
        #expect(await echoes.discount(for: pane, waitStart: .now).transform("reset") == "")
    }

    @Test("word boundaries preserve output substrings and mask punctuation")
    func wordBoundaries() {
        #expect(PaneEchoMask.mask("ready y", echoes: ["y"]) == "ready ")
        #expect(PaneEchoMask.mask("prompt>!echo!next", echoes: ["!echo!"]) == "prompt>next")
        #expect(PaneEchoMask.mask("wordé / word", echoes: ["word"]) == "wordé / ")
    }

    @Test("settled panes include output without a trailing newline")
    func settledPane() async throws {
        let echoes = PaneEchoes()
        let pane = try key()
        #expect(!(await echoes.discount(for: pane, waitStart: .now).cursorRowUnsettled))
        await echoes.commit(await echoes.apply(.keys(["Enter"]), to: [pane]))
        #expect(!(await echoes.discount(for: pane, waitStart: .now).cursorRowUnsettled))
    }

    @Test("literal line endings preserve only the unsubmitted tail")
    func literalLineEndings() async throws {
        let echoes = PaneEchoes()
        let pane = try key()
        await echoes.commit(
            await echoes.apply(.literal(["one\r\ntwo\nthree\rtail"], enter: false), to: [pane])
        )
        let discount = await echoes.discount(for: pane, waitStart: .now)
        #expect(discount.transform("one / two / three / tail") == " /  /  / ")
        #expect(discount.cursorRowUnsettled)
    }

    @Test("waits retain seen echoes after expiry and record eviction")
    func retainedDiscounts() async throws {
        let echoes = PaneEchoes()
        let pane = try key()
        let started = ContinuousClock.now
        let wait = PaneEchoes.Wait(key: pane, source: echoes)
        await echoes.commit(await echoes.apply(.keys(["old", "Enter"]), to: [pane], now: started))
        #expect(await wait.discount(now: started).transform("old") == "")
        let expired = started.advanced(by: .seconds(11))
        #expect(await echoes.discount(for: pane, waitStart: expired).transform("old") == "old")
        #expect(await wait.discount(now: expired).transform("old") == "")
        for index in 0..<5 {
            await echoes.commit(
                await echoes.apply(.keys(["line\(index)", "Enter"]), to: [pane], now: expired)
            )
        }
        let capped = await echoes.discount(for: pane, waitStart: expired)
        #expect(capped.transform("line0 line4") == "line0 ")
        let idle = expired.advanced(by: .seconds(121))
        #expect(await echoes.snapshot(for: pane, now: idle).echoes.isEmpty)
        #expect(await echoes.trackedPaneCount == 0)
        #expect(await wait.discount(now: idle).transform("old") == "")
    }

    @Test("records isolate daemon generations and bound abandoned panes")
    func identityAndLifetime() async throws {
        let echoes = PaneEchoes()
        let old = try key()
        let restarted = try key(processID: 43)
        let started = ContinuousClock.now
        await echoes.commit(await echoes.apply(.keys(["old"]), to: [old], now: started))
        await echoes.commit(await echoes.apply(.keys(["new"]), to: [restarted], now: started))
        #expect(await echoes.discount(for: old, waitStart: started).transform("old new") == " new")
        #expect(
            await echoes.discount(for: restarted, waitStart: started).transform("old new") == "old "
        )
        for index in 0..<260 {
            let pane = try key(pane: PaneID(rawValue: "%\(index + 2)")!)
            await echoes.commit(await echoes.apply(.keys(["abandoned"]), to: [pane], now: started))
        }
        #expect(await echoes.trackedPaneCount <= PaneEchoes.maxTrackedPanes)
        _ = await echoes.snapshot(for: old, now: started.advanced(by: .seconds(121)))
        #expect(await echoes.trackedPaneCount == 0)
    }
}
