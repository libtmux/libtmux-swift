import Foundation
import LibTmux

let server = try Server(socketName: "libtmux-swift-example-\(UUID().uuidString.prefix(8))")
let owner = try await server.newOwnedServer(bootstrapSession: "example")
try await owner.withValue { server in
    print("Owned server has \(try await server.sessions().count) session")
}
print("Owned daemon exited")
