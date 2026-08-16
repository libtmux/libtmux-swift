import LibTmux

let server = try Server(socketName: "work")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
