import SpikeSupport

/// The tmux listing a projection is expressed against. A field is only
/// meaningful inside its own scope, so the scope travels with the projection
/// rather than being inferred from the command that carried it.
package enum FormatScope: String, Sendable, Codable, CaseIterable {
    case session
    case window
    case pane
    case client
    case buffer
}

/// A stable identity for a projected field. It never contains a tmux format
/// name, so renaming the tmux side cannot renumber a wire schema.
package struct FormatFieldID: Sendable, Hashable, Codable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

package enum FormatValueKind: Sendable, Hashable, Codable {
    case text
    case integer
    case flag
}

package struct FormatField: Sendable, Hashable, Codable {
    package let id: FormatFieldID
    /// The tmux format name, without the surrounding `#{}`.
    package let name: String
    package let kind: FormatValueKind

    package init(id: FormatFieldID, name: String, kind: FormatValueKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

package struct FormatProjection: Sendable, Hashable, Codable {
    package let scope: FormatScope
    package let fields: [FormatField]

    package init(scope: FormatScope, fields: [FormatField]) {
        self.scope = scope
        self.fields = fields
    }
}

package enum FormatValue: Sendable, Hashable {
    case text(String)
    case integer(Int)
    case flag(Bool)
}

package struct FormatRow: Sendable, Hashable {
    package let values: [FormatFieldID: FormatValue]

    package init(values: [FormatFieldID: FormatValue]) {
        self.values = values
    }

    package subscript(field: FormatFieldID) -> FormatValue? {
        values[field]
    }
}

/// Every way a well-formed reply can still fail to yield rows. Each case names
/// the row it failed on so a caller can attribute the failure to one object
/// rather than to the listing.
package enum ProjectionDecodingError: Error, Sendable, Hashable {
    case fieldCountMismatch(rowIndex: Int, expected: Int, actual: Int)
    case invalidEncoding(rowIndex: Int)
    case invalidValue(rowIndex: Int, field: FormatFieldID, raw: String)
}

package enum SnapshotConsistencyError: Error, Sendable, Hashable {
    case incarnationChanged
    case incarnationUnreadable
}

/// The boundary a strict listing stops at. Converting a documented failure to
/// an empty array is an operation policy that lives above this type; nothing
/// here knows whether the eventual public accessor is lenient.
package enum StrictListingResult<Row: Sendable>: Sendable {
    case rows([Row])
    case commandFailure(ProcessReply)
    case decodingFailure(ProjectionDecodingError)
    case consistencyFailure(SnapshotConsistencyError)
}

extension StrictListingResult: Equatable where Row: Equatable {}

/// A framing decides how projected fields are made recoverable from one tmux
/// reply: what `-F` template to send, and how to split what comes back.
package protocol ReplyFraming: Sendable {
    /// Names the contender in evidence, so a rejected framing keeps its
    /// counterexamples attributable.
    var identifier: String { get }

    func template(for projection: FormatProjection) -> String

    func decodeRows(
        _ bytes: [UInt8],
        projection: FormatProjection
    ) -> Result<[FormatRow], ProjectionDecodingError>
}
