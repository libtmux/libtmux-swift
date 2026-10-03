import Foundation
import LibTmux
import TmuxFixture

@main
struct ApiQueryPanes {
    static func main() async {
        do {
            try await withTmuxServer { @Sendable server in
                guard let original = try await server.panes().first else {
                    throw ExampleError.paneMissing
                }
                _ = try await server.split(original, direction: .right)
                let expression = try FilterExpr<Pane>.where(\.isActive, .equals(true))
                let active = try await server.panes(where: expression)
                print("Active panes: \(active.count)")
                print("Original stays active: \(active.contains { $0.id == original.id })")
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
