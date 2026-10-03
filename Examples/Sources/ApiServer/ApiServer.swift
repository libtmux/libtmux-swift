import Foundation
import LibTmux
import TmuxFixture

@main
struct ApiServer {
    static func main() async {
        do {
            try await withTmuxServer { @Sendable fixture in
                guard case let .socketPath(path) = fixture.endpoint else {
                    throw ExampleError.expectedSocketPath
                }
                let server = try Server(
                    socketPath: path,
                    tmuxExecutable: fixture.tmuxExecutable,
                    configurationFile: "/dev/null"
                )
                let names = try await server.sessions().map(\.name).sorted()
                print("Sessions: \(names.joined(separator: ", "))")
            }
        } catch {
            FileHandle.standardError.write(Data("Example failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    enum ExampleError: Error {
        case expectedSocketPath
    }
}
