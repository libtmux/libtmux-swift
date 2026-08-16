// The examples in <doc:Filtering>, and the filtering section of the README.

import LibTmux

public func locally(_ server: Server) async throws -> [Pane] {
    let editors = try await server.panes().filter { $0.currentCommand == "nvim" }
    return editors
}

public func travelling(_ server: Server) async throws -> [Pane] {
    let expression = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
    let matching = try await server.panes().filter(expression)
    return matching
}
