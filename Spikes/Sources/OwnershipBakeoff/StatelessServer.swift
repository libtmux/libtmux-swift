import SpikeSupport

package struct StatelessServer: Sendable {
    package let locator: ServerLocator
    private let transport: any ProcessTransport
    private let scheduler: RuntimeScheduler?

    package init(
        locator: ServerLocator,
        transport: any ProcessTransport,
        scheduler: RuntimeScheduler
    ) {
        self.locator = locator
        self.transport = transport
        self.scheduler = scheduler
    }

    private init(
        locator: ServerLocator,
        transport: any ProcessTransport,
        scheduler: RuntimeScheduler?
    ) {
        self.locator = locator
        self.transport = transport
        self.scheduler = scheduler
    }

    package static func uncoordinated(
        locator: ServerLocator,
        transport: any ProcessTransport
    ) -> StatelessServer {
        StatelessServer(locator: locator, transport: transport, scheduler: nil)
    }

    package func command(_ request: ProcessRequest) async throws -> ProcessReply {
        guard let scheduler else {
            return try await transport.run(request)
        }
        let selectedTransport = transport
        return try await scheduler.withPermit(
            mode: .shared,
            label: request.schedulerLabel
        ) {
            try await selectedTransport.run(request)
        }
    }

    package func run(_ requests: [ProcessRequest]) async throws -> [ProcessReply] {
        guard let scheduler else {
            return try await runUncoordinated(requests)
        }
        let selectedTransport = transport
        let label = requests.first?.schedulerLabel ?? "program"
        return try await scheduler.withPermit(mode: .exclusive, label: label) {
            try await Self.run(requests, transport: selectedTransport)
        }
    }

    package func child() -> StatelessChild {
        StatelessChild(server: self)
    }

    private func runUncoordinated(_ requests: [ProcessRequest]) async throws -> [ProcessReply] {
        try await Self.run(requests, transport: transport)
    }

    private static func run(
        _ requests: [ProcessRequest],
        transport: any ProcessTransport
    ) async throws -> [ProcessReply] {
        var replies: [ProcessReply] = []
        replies.reserveCapacity(requests.count)
        for request in requests {
            replies.append(try await transport.run(request))
        }
        return replies
    }
}

package struct StatelessChild: Sendable {
    private let server: StatelessServer

    fileprivate init(server: StatelessServer) {
        self.server = server
    }

    package func command(_ request: ProcessRequest) async throws -> ProcessReply {
        try await server.command(request)
    }
}
