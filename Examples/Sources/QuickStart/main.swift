// The example the documentation opens with, and the one the README opens with.
//
// Snippets are compiled by `swift build`, so an example that stops compiling
// stops the build rather than sitting in the documentation being wrong.

import LibTmux

let server = try Server(socketPath: "/tmp/work.sock")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
