// The examples in <doc:Filtering>, and the filtering section of the README.

import LibTmux

public func locally(_ server: Server) async throws -> [Pane] {
    let editors = try await server.panes().filter { $0.currentCommand == "nvim" }
    return editors
}

public func travelling(_ server: Server) async throws -> [Pane] {
    let expression = FilterExpr<Pane>.where(
        Pane.FilterFields.currentCommand, .isIn(["nvim", "vim"]))
    let matching = try await server.panes().filter(expression)
    return matching
}

public func travellingByPattern(_ server: Server) async throws -> [Pane] {
    let editors = try RegexPattern("^(n?vim|hx)$", options: [.caseInsensitive])
    let expression = FilterExpr<Pane>.where(Pane.FilterFields.currentCommand, .matches(editors))
    let matching = try await server.panes().filter(expression)
    return matching
}
