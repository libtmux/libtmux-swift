import LibTmux

private func requireTmuxError<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws(TmuxError) -> Result
) {}

private func compileTypedTmuxFailures(
    server: Server,
    control: ControlSession,
    pane: Pane,
    subscription: FormatSubscription
) {
    requireTmuxError { () async throws(TmuxError) -> ControlReply in
        try await control.send(TmuxCommand("display-message"))
    }
    requireTmuxError { () async throws(TmuxError) -> Void in
        try await control.watch(subscription)
    }
    requireTmuxError { () async throws(TmuxError) -> Void in
        try await control.stopWatching(subscription.name)
    }
    requireTmuxError { () async throws(TmuxError) -> OutputWait in
        try await server.waitForOutput(in: pane)
    }
}
