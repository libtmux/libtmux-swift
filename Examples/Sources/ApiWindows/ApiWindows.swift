import Foundation
import LibTmux
import TmuxFixture

@main
struct ApiWindows {
    static func main() async {
        do {
            try await withTmuxServer { @Sendable server in
                let session = try await server.newSession(
                    named: "work", windowName: "editor")
                _ = try await server.newWindow(in: session, named: "logs")
                let windows = try await server.windows()
                let created = windows.filter {
                    ["editor", "logs"].contains($0.name)
                }
                for window in created.sorted(by: { $0.name < $1.name }) {
                    print("\(window.name): \(window.paneCount) pane")
                }
            }
        } catch {
            FileHandle.standardError.write(
                Data("Example failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
