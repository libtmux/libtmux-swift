// The examples in <doc:Filtering>, and the filtering section of the README.

import LibTmux

func locally(_ server: Server) async throws {
    let editors = try await server.panes().filter { $0.currentCommand == "nvim" }
    print(editors.count)
}

func travelling(_ server: Server) async throws {
    let expression = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
    let matching = try await server.panes().filter(expression)
    print(matching.count)
}
