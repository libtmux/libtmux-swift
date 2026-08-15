import Foundation

private struct FieldDeclaration {
    let root: String
    let modelID: String
    let valueType: String
    let property: String
    let fieldID: String
}

private enum Cardinality {
    case one
    case many
}

private struct RelationDeclaration {
    let root: String
    let modelID: String
    let projectedType: String
    let relatedType: String
    let property: String
    let relationID: String
    let cardinality: Cardinality
}

private let fields = [
    FieldDeclaration(
        root: "Pane",
        modelID: ".pane",
        valueType: "String",
        property: "command",
        fieldID: ".paneCommand"
    ),
    FieldDeclaration(
        root: "Pane",
        modelID: ".pane",
        valueType: "String",
        property: "title",
        fieldID: ".paneTitle"
    ),
    FieldDeclaration(
        root: "Pane",
        modelID: ".pane",
        valueType: "Int",
        property: "width",
        fieldID: ".paneWidth"
    ),
    FieldDeclaration(
        root: "Pane",
        modelID: ".pane",
        valueType: "String?",
        property: "alternateTitle",
        fieldID: ".paneAlternateTitle"
    ),
    FieldDeclaration(
        root: "PaneSession",
        modelID: ".paneSession",
        valueType: "String",
        property: "name",
        fieldID: ".paneSessionName"
    ),
    FieldDeclaration(
        root: "RelatedPane",
        modelID: ".relatedPane",
        valueType: "String",
        property: "command",
        fieldID: ".relatedPaneCommand"
    ),
]

private let relations = [
    RelationDeclaration(
        root: "Pane",
        modelID: ".pane",
        projectedType: "PaneSession?",
        relatedType: "PaneSession",
        property: "session",
        relationID: ".paneSession",
        cardinality: .one
    ),
    RelationDeclaration(
        root: "Pane",
        modelID: ".pane",
        projectedType: "[RelatedPane]",
        relatedType: "RelatedPane",
        property: "relatedPanes",
        relationID: ".paneRelatedPanes",
        cardinality: .many
    ),
]

private func renderFields(_ declarations: [FieldDeclaration]) -> [String] {
    let root = declarations[0].root
    var lines = ["extension FilterExpr where Root == \(root) {"]
    if declarations.count == 1 {
        let field = declarations[0]
        lines += [
            "    package static func `where`(",
            "        _ keyPath: KeyPath<\(root), Projected<\(field.valueType)>>,",
            "        _ operation: FilterOperator<\(field.valueType)>",
            "    ) throws(QueryConstructionError) -> Self {",
            "        guard keyPath == \\\(root).\(field.property) else { throw .unsupportedField }",
            "        return Self(",
            "            node: .predicate(",
            "                model: \(field.modelID),",
            "                field: \(field.fieldID),",
            "                operation: operation.operation",
            "            )",
            "        )",
            "    }",
            "}",
        ]
        return lines
    }

    lines += [
        "    package static func `where`<Value>(",
        "        _ keyPath: KeyPath<\(root), Projected<Value>>,",
        "        _ operation: FilterOperator<Value>",
        "    ) throws(QueryConstructionError) -> Self {",
        "        let field: FieldID",
        "        switch keyPath as AnyKeyPath {",
    ]
    for field in declarations {
        lines.append(
            "        case \\\(root).\(field.property): field = \(field.fieldID)"
        )
    }
    lines += [
        "        default: throw .unsupportedField",
        "        }",
        "        return Self(",
        "            node: .predicate(",
        "                model: \(declarations[0].modelID),",
        "                field: field,",
        "                operation: operation.operation",
        "            )",
        "        )",
        "    }",
        "}",
    ]
    return lines
}

private func renderRelation(_ declaration: RelationDeclaration) -> [String] {
    let operatorType: String
    let quantifier: String
    switch declaration.cardinality {
    case .one:
        operatorType = "ToOneFilterOperator"
        quantifier = ".is"
    case .many:
        operatorType = "ToManyFilterOperator"
        quantifier = "operation.quantifier"
    }
    return [
        "",
        "extension FilterExpr where Root == \(declaration.root) {",
        "    package static func `where`(",
        "        _ keyPath: KeyPath<\(declaration.root), Projected<\(declaration.projectedType)>>,",
        "        _ operation: \(operatorType)<\(declaration.relatedType)>",
        "    ) throws(QueryConstructionError) -> Self {",
        "        guard keyPath == \\\(declaration.root).\(declaration.property) else {",
        "            throw .unsupportedRelation",
        "        }",
        "        return Self(",
        "            node: .relation(",
        "                model: \(declaration.modelID),",
        "                relation: \(declaration.relationID),",
        "                quantifier: \(quantifier),",
        "                expression: operation.expression",
        "            )",
        "        )",
        "    }",
        "}",
    ]
}

private func renderSource() -> String {
    let rootOrder = fields.map(\.root).reduce(into: [String]()) { roots, root in
        if roots.last != root { roots.append(root) }
    }
    var lines: [String] = []
    for root in rootOrder {
        if !lines.isEmpty { lines.append("") }
        lines += renderFields(fields.filter { $0.root == root })
    }
    for relation in relations {
        lines += renderRelation(relation)
    }
    lines += [
        "",
        "package func `where`(",
        "    _ keyPath: KeyPath<Pane, Projected<String>>,",
        "    _ operation: FilterOperator<String>",
        ") throws(QueryConstructionError) -> FilterExpr<Pane> {",
        "    try FilterExpr<Pane>.where(keyPath, operation)",
        "}",
        "",
    ]
    return lines.joined(separator: "\n")
}

private let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1, arguments[0] == "--check" || arguments[0] == "--write" else {
    FileHandle.standardError.write(
        Data("usage: generate-key-path-switch.swift --check|--write\n".utf8)
    )
    exit(64)
}

let script = URL(fileURLWithPath: #filePath)
let destination =
    script
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Sources/KeyPathBakeoff/GeneratedSwitch.swift")
let bytes = Data(renderSource().utf8)

if arguments[0] == "--write" {
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try bytes.write(to: destination, options: .atomic)
} else {
    guard let existing = try? Data(contentsOf: destination), existing == bytes else {
        FileHandle.standardError.write(Data("generated switch is missing or stale\n".utf8))
        exit(1)
    }
}
