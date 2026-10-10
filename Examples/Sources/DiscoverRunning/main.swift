import LibTmux

let result = try await TmuxServers.discover()
for server in result.servers {
    print("\(server.socketPath): \(server.sessionCount) sessions")
}
for diagnostic in result.diagnostics {
    print("\(diagnostic.kind): \(diagnostic.path): \(diagnostic.detail)")
}
print("Truncated: \(result.truncated)")
