import Foundation
import LibTmux
import TmuxFixture

@main
struct ApiNewWindow {
    static func main() async {
        do {
            try await withTmuxServer { @Sendable server in
                let session = try await server.newSession(named: "work", windowName: "editor")
                let appearance = try await server.newWindow(in: session, named: "logs", at: 3)
                print("Window: \(appearance.window.name)")
                print("Index: \(appearance.link.index)")
                print("Same session: \(appearance.link.sessionID == session.id)")
            }
        } catch {
            FileHandle.standardError.write(Data("Example failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
