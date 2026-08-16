import LibTmux

let server = try Server(socketName: "libtmux-swift")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
