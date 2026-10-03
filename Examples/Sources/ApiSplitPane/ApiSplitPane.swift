import Foundation
import LibTmux
import TmuxFixture

@main
struct ApiSplitPane {
    static func main() async {
        do {
            try await withTmuxServer { @Sendable server in
                guard let original = try await server.panes().first else {
                    throw ExampleError.paneMissing
                }
                let created = try await server.split(
                    original,
                    direction: .right,
                    size: .percentage(40)
                )
                let panes = try await server.panes().filter { $0.windowID == original.windowID }
                print("Panes in window: \(panes.count)")
                print("Same window: \(created.windowID == original.windowID)")
            }
        } catch {
            FileHandle.standardError.write(Data("Example failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    enum ExampleError: Error {
        case paneMissing
    }
}
