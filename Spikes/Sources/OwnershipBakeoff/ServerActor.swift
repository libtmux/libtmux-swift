import SpikeSupport

package actor ServerActor {
    package nonisolated let locator: ServerLocator
    private let transport: any ProcessTransport
    private let scheduler: RuntimeScheduler

    package init(
        locator: ServerLocator,
        transport: any ProcessTransport,
        schedulerObserver: SchedulerObserver,
        postGrantCheckpoint: RuntimeScheduler.PostGrantCheckpoint? = nil
    ) {
        self.locator = locator
        self.transport = transport
        scheduler = RuntimeScheduler(
            observer: schedulerObserver,
            postGrantCheckpoint: postGrantCheckpoint
        )
    }

    package func command(_ request: ProcessRequest) async throws -> ProcessReply {
        let selectedTransport = transport
        let selectedScheduler = scheduler
        return try await selectedScheduler.withPermit(
            mode: .shared,
            label: request.schedulerLabel
        ) {
            try await selectedTransport.run(request)
        }
    }

    package func run(_ requests: [ProcessRequest]) async throws -> [ProcessReply] {
        let selectedTransport = transport
        let selectedScheduler = scheduler
        let label = requests.first?.schedulerLabel ?? "program"
        return try await selectedScheduler.withPermit(mode: .exclusive, label: label) {
            var replies: [ProcessReply] = []
            replies.reserveCapacity(requests.count)
            for request in requests {
                replies.append(try await selectedTransport.run(request))
            }
            return replies
        }
    }

    package func child() -> ServerActorChild {
        ServerActorChild(server: self)
    }
}

package struct ServerActorChild: Sendable {
    private let server: ServerActor

    fileprivate init(server: ServerActor) {
        self.server = server
    }

    package func command(_ request: ProcessRequest) async throws -> ProcessReply {
        try await server.command(request)
    }
}
