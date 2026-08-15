import Foundation

package enum TmuxEndpoint: Sendable, Codable, Hashable {
    case socketName(String)
    case socketPath(String)
}

package enum TmuxEndpointError: Error, Sendable, Equatable {
    case emptyEndpoint
}

package struct ServerIncarnationID: Sendable, Codable, Hashable {
    package let endpoint: TmuxEndpoint
    package let token: UUID

    package init(endpoint: TmuxEndpoint, token: UUID) throws {
        guard !endpoint.value.isEmpty else {
            throw TmuxEndpointError.emptyEndpoint
        }

        self.endpoint = endpoint
        self.token = token
    }
}

private extension TmuxEndpoint {
    var value: String {
        switch self {
        case let .socketName(name), let .socketPath(name):
            name
        }
    }
}
