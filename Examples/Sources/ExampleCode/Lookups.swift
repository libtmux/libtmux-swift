// The examples in the README's "Finding one object" and "Typed errors across a
// scope" sections, and in <doc:Modes>.

import LibTmux

public func findOneObjectWithoutListingTheRest(
    _ server: Server,
    _ pane: Pane
) async throws -> (Session?, Pane?) {
    let work = try await server.session(named: "work")
    let fresh = try await server.refresh(pane)
    return (work, fresh)
}

public func letTmuxDoTheNarrowing(
    _ server: Server,
    _ expression: FilterExpr<Pane>
) async throws -> [Pane] {
    let matching = try await server.panes(where: expression)
    return matching
}

public func askTmuxForTheEditors(_ server: Server) async throws -> [Pane] {
    let editors = try await server.panes(
        where: .where(\.currentCommand, .isIn(["nvim", "vim"]))
    )
    return editors
}

public func typedErrorsAcrossAScope(_ server: Server) async throws -> [String] {
    func names(_ server: Server) async throws(TmuxError) -> [String] {
        try await withTmuxError {
            try await server.using(.connected(to: "main")) { server in
                try await server.sessions().map(\.name)
            }
        }
    }
    return try await names(server)
}
