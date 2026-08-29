import Foundation

fileprivate struct RegexInstruction: Sendable {
    enum Operation: Sendable {
        case consume(RegexPredicate)
        case split
        case epsilon
        case assertStart
        case assertEnd
        case accept
    }

    let operation: Operation
    var first: Int?
    var second: Int?
}

struct RegexProgram: Sendable {
    fileprivate let instructions: [RegexInstruction]
    fileprivate let start: Int

    func containsMatch(
        in input: String,
        options: RegexPattern.Options,
        meter: inout RegexWorkMeter
    ) throws(RegexMatchError) -> Bool {
        var active: Set<Int> = []
        var position = 0

        for character in input {
            active.insert(start)
            active = try epsilonClosure(
                active,
                atStart: position == 0,
                atEnd: false,
                meter: &meter
            )
            if active.contains(where: isAccept) { return true }

            var next: Set<Int> = []
            let characterWork = max(1, String(character).utf8.count)
            for state in active {
                guard case let .consume(predicate) = instructions[state].operation else {
                    continue
                }
                try meter.charge(characterWork)
                if try predicate.matches(
                    character,
                    characterUTF8Bytes: characterWork,
                    options: options,
                    meter: &meter
                ),
                    let successor = instructions[state].first
                {
                    next.insert(successor)
                }
            }
            active = next
            position += 1
        }

        active.insert(start)
        active = try epsilonClosure(
            active,
            atStart: position == 0,
            atEnd: true,
            meter: &meter
        )
        return active.contains(where: isAccept)
    }

    private func epsilonClosure(
        _ seeds: Set<Int>,
        atStart: Bool,
        atEnd: Bool,
        meter: inout RegexWorkMeter
    ) throws(RegexMatchError) -> Set<Int> {
        var result = seeds
        var pending = Array(seeds)
        while let state = pending.popLast() {
            try meter.charge(1)
            let instruction = instructions[state]
            let successors: [Int]
            switch instruction.operation {
            case .split:
                successors = [instruction.first, instruction.second].compactMap { $0 }
            case .epsilon:
                successors = [instruction.first].compactMap { $0 }
            case .assertStart where atStart, .assertEnd where atEnd:
                successors = [instruction.first].compactMap { $0 }
            default:
                successors = []
            }
            for successor in successors where result.insert(successor).inserted {
                pending.append(successor)
            }
        }
        return result
    }

    private func isAccept(_ state: Int) -> Bool {
        if case .accept = instructions[state].operation { return true }
        return false
    }
}

struct RegexWorkMeter {
    private let maximum: Int
    private var used = 0

    init(maximum: Int) {
        self.maximum = maximum
    }

    mutating func charge(_ amount: Int) throws(RegexMatchError) {
        guard amount <= maximum - used else {
            throw .workLimitExceeded(maximum: maximum)
        }
        used += amount
    }
}

fileprivate struct RegexPatch {
    enum Slot {
        case first
        case second
    }

    let instruction: Int
    let slot: Slot
}

fileprivate struct RegexFragment {
    let start: Int
    let exits: [RegexPatch]
}

struct RegexCompiler {
    private let maximumStates: Int
    private var instructions: [RegexInstruction] = []

    init(maximumStates: Int) {
        self.maximumStates = maximumStates
    }

    mutating func finish(
        _ syntax: RegexSyntax,
        endOffset: Int
    ) throws(RegexCompileError) -> RegexProgram {
        let fragment = try compile(syntax)
        let accept = try emit(.accept, offset: endOffset)
        patch(fragment.exits, to: accept)
        return RegexProgram(instructions: instructions, start: fragment.start)
    }

    private mutating func compile(
        _ syntax: RegexSyntax
    ) throws(RegexCompileError) -> RegexFragment {
        switch syntax.kind {
        case .empty:
            let instruction = try emit(.epsilon, offset: syntax.offset)
            return RegexFragment(
                start: instruction,
                exits: [RegexPatch(instruction: instruction, slot: .first)]
            )
        case let .predicate(predicate):
            let instruction = try emit(.consume(predicate), offset: syntax.offset)
            return RegexFragment(
                start: instruction,
                exits: [RegexPatch(instruction: instruction, slot: .first)]
            )
        case .start:
            let instruction = try emit(.assertStart, offset: syntax.offset)
            return RegexFragment(
                start: instruction,
                exits: [RegexPatch(instruction: instruction, slot: .first)]
            )
        case .end:
            let instruction = try emit(.assertEnd, offset: syntax.offset)
            return RegexFragment(
                start: instruction,
                exits: [RegexPatch(instruction: instruction, slot: .first)]
            )
        case let .concatenation(parts):
            var result: RegexFragment?
            for part in parts {
                result = concatenate(result, try compile(part))
            }
            if let result { return result }
            return try compile(RegexSyntax(kind: .empty, offset: syntax.offset))
        case let .alternation(choices):
            var fragments: [RegexFragment] = []
            for choice in choices {
                fragments.append(try compile(choice))
            }
            while fragments.count > 1 {
                let left = fragments.removeFirst()
                let right = fragments.removeFirst()
                let split = try emit(
                    .split,
                    first: left.start,
                    second: right.start,
                    offset: syntax.offset
                )
                fragments.insert(
                    RegexFragment(start: split, exits: left.exits + right.exits),
                    at: 0
                )
            }
            return fragments[0]
        case let .repetition(child, minimum, maximum):
            return try compileRepetition(
                child,
                minimum: minimum,
                maximum: maximum,
                offset: syntax.offset
            )
        }
    }

    private mutating func compileRepetition(
        _ child: RegexSyntax,
        minimum: Int,
        maximum: Int?,
        offset: Int
    ) throws(RegexCompileError) -> RegexFragment {
        var result: RegexFragment?
        for _ in 0..<minimum {
            result = concatenate(result, try compile(child))
        }

        if let maximum {
            for _ in minimum..<maximum {
                let body = try compile(child)
                let split = try emit(.split, first: body.start, offset: offset)
                result = concatenate(
                    result,
                    RegexFragment(
                        start: split,
                        exits: body.exits + [RegexPatch(instruction: split, slot: .second)]
                    )
                )
            }
        } else {
            let body = try compile(child)
            let split = try emit(.split, first: body.start, offset: offset)
            patch(body.exits, to: split)
            result = concatenate(
                result,
                RegexFragment(
                    start: split,
                    exits: [RegexPatch(instruction: split, slot: .second)]
                )
            )
        }

        if let result { return result }
        return try compile(RegexSyntax(kind: .empty, offset: offset))
    }

    private mutating func concatenate(
        _ left: RegexFragment?,
        _ right: RegexFragment
    ) -> RegexFragment {
        guard let left else { return right }
        patch(left.exits, to: right.start)
        return RegexFragment(start: left.start, exits: right.exits)
    }

    private mutating func emit(
        _ operation: RegexInstruction.Operation,
        first: Int? = nil,
        second: Int? = nil,
        offset: Int
    ) throws(RegexCompileError) -> Int {
        guard instructions.count < maximumStates else {
            throw .stateLimitExceeded(offset: offset, maximum: maximumStates)
        }
        instructions.append(
            RegexInstruction(operation: operation, first: first, second: second)
        )
        return instructions.count - 1
    }

    private mutating func patch(_ exits: [RegexPatch], to target: Int) {
        for exit in exits {
            switch exit.slot {
            case .first:
                instructions[exit.instruction].first = target
            case .second:
                instructions[exit.instruction].second = target
            }
        }
    }
}
