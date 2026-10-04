import Foundation
import LibTmux
import TmuxFixture

@main
struct ApiSessions {
    static func main() async {
        do {
            try await withTmuxServer { @Sendable server in
                _ = try await server.newSession(named: "work")
                _ = try await server.newSession(named: "build")
                let sessions = try await server.sessions()
                for session in sessions.sorted(by: { $0.name < $1.name }) {
                    print("\(session.name): \(session.windowCount) window")
                }
            }
        } catch {
            FileHandle.standardError.write(
                Data("Example failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
