/// Joins projected fields with a single literal separator, the shape the
/// Python library already ships.
///
/// tmux expands each `#{}` exactly once and never escapes the result, so a
/// value that itself contains the separator splits into extra fields. That is
/// recoverable only because the field count is fixed: an over-long row is
/// reported as a count mismatch rather than silently reassembled, which would
/// attribute one object's value to its neighbour.
package struct RawSeparatorFraming: ReplyFraming {
    /// U+241E SYMBOL FOR RECORD SEPARATOR — a printable glyph rather than the
    /// C0 control it depicts, matching the existing Python wire shape.
    package static let separator: Character = "\u{241E}"

    package let identifier = "raw-separator"

    package init() {}

    package func template(for projection: FormatProjection) -> String {
        projection.fields
            .map { "#{\($0.name)}" }
            .joined(separator: String(Self.separator))
    }

    package func decodeRows(
        _ bytes: [UInt8],
        projection: FormatProjection
    ) -> Result<[FormatRow], ProjectionDecodingError> {
        var rows: [FormatRow] = []
        for (rowIndex, line) in framedLines(bytes).enumerated() {
            guard let text = String(bytes: line, encoding: .utf8) else {
                return .failure(.invalidEncoding(rowIndex: rowIndex))
            }
            let rawValues = text.split(
                separator: Self.separator,
                omittingEmptySubsequences: false
            )
            guard rawValues.count == projection.fields.count else {
                return .failure(
                    .fieldCountMismatch(
                        rowIndex: rowIndex,
                        expected: projection.fields.count,
                        actual: rawValues.count
                    )
                )
            }
            var values: [FormatFieldID: FormatValue] = [:]
            for (field, raw) in zip(projection.fields, rawValues) {
                guard let value = decodeValue(String(raw), kind: field.kind) else {
                    return .failure(
                        .invalidValue(
                            rowIndex: rowIndex,
                            field: field.id,
                            raw: String(raw)
                        )
                    )
                }
                values[field.id] = value
            }
            rows.append(FormatRow(values: values))
        }
        return .success(rows)
    }
}

/// Splits on newlines, dropping only the terminator tmux writes after the last
/// row. A listing of zero rows and a listing of one all-empty row differ by
/// exactly that byte, so the distinction cannot be recovered later.
private func framedLines(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
    var remaining = bytes[...]
    if remaining.last == UInt8(ascii: "\n") {
        remaining = remaining.dropLast()
    }
    if remaining.isEmpty { return [] }
    return remaining.split(
        separator: UInt8(ascii: "\n"),
        omittingEmptySubsequences: false
    )
}

private func decodeValue(_ raw: String, kind: FormatValueKind) -> FormatValue? {
    switch kind {
    case .text:
        return .text(raw)
    case .integer:
        return Int(raw).map(FormatValue.integer)
    case .flag:
        switch raw {
        case "0": return .flag(false)
        case "1": return .flag(true)
        default: return nil
        }
    }
}
