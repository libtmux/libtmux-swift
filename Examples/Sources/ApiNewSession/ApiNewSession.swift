import Foundation
import LibTmux
import TmuxFixture

@main
struct ApiNewSession {
    static func main() async {
        do {
            try await withTmuxServer { @Sendable server in
                let session = try await server.newSession(named: "work", windowName: "editor")
                _ = try await server.newWindow(in: session, named: "logs")
                guard let refreshed = try await server.session(session.id) else {
                    throw ExampleError.sessionDisappeared
                }
                print("Created: \(session.name)")
                print("Original windows: \(session.windowCount)")
                print("Current windows: \(refreshed.windowCount)")
            }
        } catch {
            FileHandle.standardError.write(Data("Example failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    enum ExampleError: Error {
        case sessionDisappeared
    }
}
