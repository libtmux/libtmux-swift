import Foundation
import LibTmux
import TmuxFixture

@main
struct ApiCapture {
    static func main() async {
        do {
            try await withTmuxServer { @Sendable server in
                guard let pane = try await server.panes().first else {
                    throw ExampleError.paneMissing
                }
                let marker = "libtmux-swift-api"
                try await server.sendKeys(["printf '%s\\n' \(marker)"], to: pane, literally: true)
                try await server.sendKeys(["Enter"], to: pane)

                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(5))
                while clock.now < deadline {
                    let lines = try await server.capture(pane, includingHistory: true)
                    if lines.contains(marker) {
                        print(marker)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw ExampleError.outputTimedOut
            }
        } catch {
            FileHandle.standardError.write(Data("Example failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    enum ExampleError: Error {
        case paneMissing
        case outputTimedOut
    }
}
