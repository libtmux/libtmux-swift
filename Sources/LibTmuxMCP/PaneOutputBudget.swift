enum PaneOutputBudget {
    static let sourceBytes = 262_144
    static let returnedBytes = 128_000
    static let maximumLines = 2_000
    static let maximumMatches = 200
    static let defaultCaptureLines = 200
    static let defaultSearchLines = 500

    struct Tail {
        let lines: [String]
        let droppedLines: Int
    }

    static func tail(
        _ lines: [String],
        afterDropping droppedLines: Int = 0
    ) throws -> Tail {
        var keptBytes = 0
        var firstKept = lines.endIndex
        for index in lines.indices.reversed() {
            let lineBytes = lines[index].utf8.count
            if firstKept == lines.endIndex, lineBytes > returnedBytes {
                throw ToolError.refusedForSafety(
                    "one pane row exceeds the 128000-byte raw text limit"
                )
            }
            let separatorBytes = firstKept == lines.endIndex ? 0 : 1
            guard lineBytes <= returnedBytes - keptBytes - separatorBytes else { break }
            keptBytes += separatorBytes + lineBytes
            firstKept = index
        }

        let byteDropped = lines.distance(from: lines.startIndex, to: firstKept)
        let (totalDropped, overflowed) = droppedLines.addingReportingOverflow(byteDropped)
        guard !overflowed else {
            throw ToolError.refusedForSafety("pane output size overflowed")
        }
        return Tail(
            lines: Array(lines[firstKept...]),
            droppedLines: totalDropped
        )
    }
}
