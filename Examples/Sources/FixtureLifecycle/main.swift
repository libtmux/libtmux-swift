import LibTmux
import TmuxFixture

try await withTmuxServer { server in
    try await server.withNewSession(named: "fixture-example") { session in
        print("Fixture session: \(session.name)")
    }
}
print("Fixture daemon exited and its root was removed")
