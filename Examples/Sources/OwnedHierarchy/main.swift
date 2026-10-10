import Foundation
import LibTmux

let server = try Server()
let session = try await server.newOwnedSession(named: "example-\(UUID().uuidString.prefix(8))")
try await session.withValue { session in
    let window = try await server.newOwnedWindow(in: session, named: "logs")
    try await window.withValue { window in
        guard let pane = try await server.panes().first(where: { $0.windowID == window.id }) else {
            throw TmuxError.staleServerValue
        }
        let split = try await server.splitOwned(pane)
        try await split.withValue { pane in
            print("Working in pane \(pane.id)")
        }
    }
}
print("Owned hierarchy cleaned up")
