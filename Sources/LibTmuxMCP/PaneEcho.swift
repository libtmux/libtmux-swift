import LibTmux

/// Tracks dispatches before tmux can expose their echo to a concurrent wait.
actor PaneEchoes {
    struct Key: Sendable, Hashable {
        let incarnation: ServerIncarnation
        let pane: PaneID
    }

    static let recentTTL = Duration.seconds(10)
    static let recentPerPane = 4
    static let maxTrackedPanes = 256
    static let deadRecordExpiry = Duration.seconds(120)
    static let maximumLineBytes = 1_048_576

    fileprivate struct Record: Sendable {
        var pending = ""
        var overflowed = false
        var inFlight = 0
        var recent: [(text: String, at: ContinuousClock.Instant)] = []
        var touched: ContinuousClock.Instant

        var hasPending: Bool { inFlight > 0 || !pending.isEmpty }
    }

    enum Dispatch: Sendable {
        case keys([String])
        case literal([String], enter: Bool)
    }

    struct Update: Sendable {
        fileprivate let entries: [(key: Key, previous: Record?)]
    }

    private var table: [Key: Record] = [:]

    // The caller holds the pane-input reservation until commit or abandon.
    func apply(
        _ dispatch: Dispatch,
        to panes: [Key],
        now: ContinuousClock.Instant = .now
    ) -> Update {
        evictStale(now: now)
        var entries: [(Key, Record?)] = []
        for key in Set(panes) {
            let previous = table[key]
            var record = previous ?? Record(touched: now)
            entries.append((key, previous))
            record.inFlight += 1
            record.touched = now
            switch dispatch {
            case let .keys(tokens):
                var erasing = false
                for token in tokens {
                    switch PaneEchoKeyModel.classify(token) {
                    case .submit, .kill:
                        erasing = false
                        remember(&record, now: now)
                        record.pending = ""
                        record.overflowed = false
                    case .erase:
                        if !erasing { remember(&record, now: now) }
                        erasing = true
                        if !record.pending.isEmpty { record.pending.removeLast() }
                    case .noop: break
                    case let .text(text):
                        erasing = false
                        append(text, to: &record, now: now)
                    case .unknown:
                        erasing = false
                        record.pending = ""
                        record.overflowed = false
                    }
                }
            case let .literal(texts, enter):
                for text in texts { append(text, to: &record, now: now) }
                if enter {
                    remember(&record, now: now)
                    record.pending = ""
                    record.overflowed = false
                }
            }
            table[key] = record
        }
        evictStale(now: now)
        return Update(entries: entries)
    }

    func commit(_ update: Update) {
        for (key, _) in update.entries {
            guard var record = table[key] else { continue }
            record.inFlight = max(0, record.inFlight - 1)
            table[key] = record
        }
    }

    func abandon(_ update: Update) {
        for (key, previous) in update.entries { table[key] = previous }
    }

    func hasPending(_ key: Key) -> Bool { table[key]?.hasPending ?? false }

    func discount(for key: Key, waitStart: ContinuousClock.Instant) -> OutputWaitDiscount {
        let snapshot = snapshot(for: key, now: waitStart)
        return OutputWaitDiscount(
            transform: { PaneEchoMask.mask($0, echoes: snapshot.echoes) },
            cursorRowUnsettled: snapshot.pending
        )
    }

    struct Snapshot: Sendable {
        let recent: [String]
        let current: String
        let pending: Bool

        var echoes: [String] { recent + (current.isEmpty ? [] : [current]) }
    }

    func snapshot(for key: Key, now: ContinuousClock.Instant = .now) -> Snapshot {
        evictStale(now: now)
        guard let record = table[key] else {
            return Snapshot(recent: [], current: "", pending: false)
        }
        return Snapshot(
            recent: record.recent.map(\.text), current: record.pending,
            pending: record.hasPending
        )
    }

    /// Retains submitted and erased echoes while refreshing the current input.
    actor Wait {
        let key: Key
        let source: PaneEchoes
        private var seen: [String] = []

        init(key: Key, source: PaneEchoes) {
            self.key = key
            self.source = source
        }

        func discount(now: ContinuousClock.Instant = .now) async -> OutputWaitDiscount {
            let snapshot = await source.snapshot(for: key, now: now)
            for echo in snapshot.recent where !seen.contains(echo) { seen.append(echo) }
            let echoes = (seen + (snapshot.current.isEmpty ? [] : [snapshot.current]))
                .sorted { $0.count > $1.count }
            return OutputWaitDiscount(
                transform: { PaneEchoMask.mask($0, echoes: echoes) },
                cursorRowUnsettled: snapshot.pending
            )
        }
    }

    #if DEBUG
        var trackedPaneCount: Int { table.count }
    #endif

    private func append(_ text: String, to record: inout Record, now: ContinuousClock.Instant) {
        let fragments = text.split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"
        }
        for (index, fragment) in fragments.enumerated() {
            if index > 0 {
                remember(&record, now: now)
                record.pending = ""
                record.overflowed = false
            }
            guard !record.overflowed else { continue }
            if record.pending.utf8.count + fragment.utf8.count > Self.maximumLineBytes {
                record.pending = ""
                record.overflowed = true
            } else {
                record.pending += fragment
            }
        }
    }

    private func remember(_ record: inout Record, now: ContinuousClock.Instant) {
        guard !record.pending.isEmpty else { return }
        record.recent.removeAll { $0.text == record.pending }
        record.recent.append((record.pending, now))
        if record.recent.count > Self.recentPerPane {
            record.recent.removeFirst(record.recent.count - Self.recentPerPane)
        }
    }

    private func evictStale(now: ContinuousClock.Instant) {
        for key in Array(table.keys) {
            guard var record = table[key] else { continue }
            if record.inFlight == 0, now - record.touched > Self.deadRecordExpiry {
                table.removeValue(forKey: key)
                continue
            }
            record.recent.removeAll { now - $0.at > Self.recentTTL }
            table[key] = record
        }
        while table.count > Self.maxTrackedPanes {
            guard
                let oldest = table.filter({ $0.value.inFlight == 0 })
                    .min(by: { $0.value.touched < $1.value.touched })?.key
            else { break }
            table.removeValue(forKey: oldest)
        }
    }
}

enum PaneEchoKeyModel {
    enum Effect {
        case erase, kill, noop, submit, unknown
        case text(String)
    }

    static let unrepresentableKeyNames: Set<String> = Set(
        [
            "BTab", "Down", "End", "Escape", "Home", "IC", "Left", "NPage", "PPage",
            "PageDown", "PageUp", "Right", "Tab", "Up",
        ] + (1...24).map { "F\($0)" }
    )

    static func classify(_ token: String) -> Effect {
        if ["Enter", "C-m", "KPEnter"].contains(token) { return .submit }
        if ["C-c", "C-u"].contains(token) { return .kill }
        if ["BSpace", "C-h"].contains(token) { return .erase }
        if token == "DC" { return .noop }
        if token == "Space" { return .text(" ") }
        if token.count == 1 { return .text(token) }
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        let modified =
            parts.count >= 2 && parts.last?.isEmpty == false
            && parts.dropLast().allSatisfy { $0 == "C" || $0 == "M" || $0 == "S" }
        if unrepresentableKeyNames.contains(token) || modified { return .unknown }
        return .text(token)
    }
}

extension TmuxTools {
    static func echoKeys(for resolution: PaneInputResolution) -> [PaneEchoes.Key] {
        resolution.configuredPanes.map {
            PaneEchoes.Key(incarnation: $0.incarnation, pane: $0.id)
        }
    }
}

enum PaneEchoMask {
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Discounts whole-word occurrences while preserving substrings in other words.
    static func withoutEcho(_ haystack: String, echo: String) -> String {
        guard !echo.isEmpty, !haystack.isEmpty, haystack.count >= echo.count else {
            return haystack
        }
        let hay = Array(haystack)
        let needle = Array(echo)
        var masked = [Bool](repeating: false, count: hay.count)
        var from = 0
        while from + needle.count <= hay.count {
            guard let offset = firstIndex(of: needle, in: hay, from: from) else { break }
            let end = offset + needle.count
            let opensAtBoundary =
                offset == 0 || !isWordCharacter(needle[0]) || !isWordCharacter(hay[offset - 1])
            let closesAtBoundary =
                end == hay.count || !isWordCharacter(needle[needle.count - 1])
                || !isWordCharacter(hay[end])
            if opensAtBoundary, closesAtBoundary {
                for index in offset..<end { masked[index] = true }
                from = end
            } else {
                from = offset + 1
            }
        }
        var result = ""
        result.reserveCapacity(hay.count)
        for (character, hidden) in zip(hay, masked) where !hidden {
            result.append(character)
        }
        return result
    }

    private static func firstIndex(of needle: [Character], in hay: [Character], from: Int) -> Int? {
        guard !needle.isEmpty else { return nil }
        var index = from
        while index + needle.count <= hay.count {
            if Array(hay[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    /// Remove every recorded echo from `text`, in order.
    static func mask(_ text: String, echoes: [String]) -> String {
        var result = text
        for echo in echoes { result = withoutEcho(result, echo: echo) }
        return result
    }
}
