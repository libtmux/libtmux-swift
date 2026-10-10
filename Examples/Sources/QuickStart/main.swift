import LibTmux

let server = try Server()
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
