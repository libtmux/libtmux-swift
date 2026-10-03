import Foundation
import LibTmux
import TmuxFixture

@main
struct ApiPanes {
    static func main() async {
        do {
            try await withTmuxServer { @Sendable server in
                let session = try await server.newSession(named: "work")
                let appearance = try await server.newWindow(in: session, named: "logs")
                let panes = try await server.panes()
                let logPanes = panes.filter { $0.windowID == appearance.window.id }
                print("Log panes: \(logPanes.count)")
                for pane in logPanes {
                    print("Active: \(pane.isActive)")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("Example failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
