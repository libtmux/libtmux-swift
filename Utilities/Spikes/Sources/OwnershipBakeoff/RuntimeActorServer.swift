import SpikeSupport

private actor ServerRuntime {
    private let transport: any ProcessTransport
    private let scheduler: RuntimeScheduler
    private let capabilitySnapshot: RuntimeCapabilities

    init(
        transport: any ProcessTransport,
        scheduler: RuntimeScheduler,
        capabilities: RuntimeCapabilities
    ) {
        self.transport = transport
        self.scheduler = scheduler
        capabilitySnapshot = capabilities
    }

    func command(_ request: ProcessRequest) async throws -> ProcessReply {
        let selectedTransport = transport
        let selectedScheduler = scheduler
        return try await selectedScheduler.withPermit(
            mode: .shared,
            label: request.schedulerLabel
        ) {
            try await selectedTransport.run(request)
        }
    }

    func run(_ requests: [ProcessRequest]) async throws -> [ProcessReply] {
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

    func capabilities() -> RuntimeCapabilities {
        capabilitySnapshot
    }
}

package struct RuntimeActorServer: Sendable {
    package let locator: ServerLocator
    private let runtime: ServerRuntime

    package init(
        locator: ServerLocator,
        transport: any ProcessTransport,
        schedulerObserver: SchedulerObserver,
        capabilities: RuntimeCapabilities = .fixture,
        postGrantCheckpoint: RuntimeScheduler.PostGrantCheckpoint? = nil
    ) {
        self.locator = locator
        runtime = ServerRuntime(
            transport: transport,
            scheduler: RuntimeScheduler(
                observer: schedulerObserver,
                postGrantCheckpoint: postGrantCheckpoint
            ),
            capabilities: capabilities
        )
    }

    package var capabilities: RuntimeCapabilities {
        get async { await runtime.capabilities() }
    }

    package func command(_ request: ProcessRequest) async throws -> ProcessReply {
        try await runtime.command(request)
    }

    package func run(_ requests: [ProcessRequest]) async throws -> [ProcessReply] {
        try await runtime.run(requests)
    }

    package func child() -> RuntimeActorChild {
        RuntimeActorChild(runtime: runtime)
    }
}

package struct RuntimeActorChild: Sendable {
    private let runtime: ServerRuntime

    fileprivate init(runtime: ServerRuntime) {
        self.runtime = runtime
    }

    package func command(_ request: ProcessRequest) async throws -> ProcessReply {
        try await runtime.command(request)
    }
}
