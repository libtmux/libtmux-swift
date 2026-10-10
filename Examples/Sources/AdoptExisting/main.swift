import Foundation
import LibTmux

let server = try Server()
let session = try await server.newSession(named: "example-\(UUID().uuidString.prefix(8))")
let owner = try await server.adopt(session)
try await owner.withValue { session in
    try await server.rename(session, to: "renamed-\(UUID().uuidString.prefix(8))")
    print("Accepted cleanup of session \(session.id)")
}
print("Adopted session cleaned up")
