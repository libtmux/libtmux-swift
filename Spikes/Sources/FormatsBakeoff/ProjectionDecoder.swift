import SpikeSupport

/// Turns one raw tmux reply into a strict listing.
///
/// A nonzero tmux exit is a reply, not a thrown error, so it arrives here as
/// data and leaves as `.commandFailure`. Deciding whether a caller sees that as
/// an empty array is a policy that lives above this type.
package enum ProjectionDecoder {
    package static func strictListing(
        reply: ProcessReply,
        projection: FormatProjection,
        framing: some ReplyFraming
    ) -> StrictListingResult<FormatRow> {
        guard reply.termination == .exited(0) else {
            return .commandFailure(reply)
        }
        switch framing.decodeRows(reply.standardOutput, projection: projection) {
        case let .success(rows):
            return .rows(rows)
        case let .failure(error):
            return .decodingFailure(error)
        }
    }
}
