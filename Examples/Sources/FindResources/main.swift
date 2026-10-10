import Foundation
import LibTmux

let server = try Server()
let session = try await server.findOrCreateSession(named: "example-\(UUID().uuidString.prefix(8))")
try await session.withValue { session in
    let window = try await server.findOrCreateWindow(in: session, named: "logs")
    try await window.withValue { window in
        let pane = try await server.findOrCreatePane(in: window, identity: "log-reader")
        try await pane.withValue { _ in
            let again = try await server.findOrCreatePane(in: window, identity: "log-reader")
            print("First created: \(pane.wasCreated); second created: \(again.wasCreated)")
        }
    }
}
print("New resources cleaned up")
