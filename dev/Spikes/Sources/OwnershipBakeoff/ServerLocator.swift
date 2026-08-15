import SpikeSupport

package struct ServerLocator: Sendable, Equatable, Hashable {
    package let endpoint: String

    package static let fixture = ServerLocator(endpoint: "ownership-fixture")
}

package struct RuntimeCapabilities: Sendable, Equatable {
    package let supportsControlMode: Bool
    package let supportsStructuredFormats: Bool

    package static let fixture = RuntimeCapabilities(
        supportsControlMode: true,
        supportsStructuredFormats: true
    )
}

extension ProcessRequest {
    package var schedulerLabel: String {
        arguments.first ?? ""
    }
}
