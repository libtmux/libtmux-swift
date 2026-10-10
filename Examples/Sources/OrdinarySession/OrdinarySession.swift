import Foundation
import LibTmux

@main
struct OrdinarySession {
    static func main() async {
        do {
            let server = try Server()
            try await server.withNewSession(named: "example-\(UUID().uuidString.prefix(8))") {
                session in
                _ = try await server.newWindow(in: session, named: "logs")
                let current = try await server.session(session.id)
                print("Created session with \(current?.windowCount ?? 0) windows")
            }
            print("Session cleaned up")
        } catch {
            FileHandle.standardError.write(Data("Example failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
