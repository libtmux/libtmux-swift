import Foundation

/// Builds the JSON Schema a tool advertises for what it answers.
///
/// A tool that says what it returns can be validated by the client and read by
/// a model without being called once to find out. MCP types `structuredContent`
/// as an object, so every schema here describes one — which is why the listings
/// answer `{"panes": [...]}` rather than a bare array.
enum Schema {
    static let string = JSONValue.object(["type": .string("string")])
    static let integer = JSONValue.object(["type": .string("integer")])
    static let number = JSONValue.object(["type": .string("number")])
    static let boolean = JSONValue.object(["type": .string("boolean")])
    /// A field the server may legitimately answer with nothing, spelled so a
    /// validating client accepts the null rather than rejecting the result.
    static let nullableString = JSONValue.object([
        "type": .array([.string("string"), .string("null")])
    ])
    static let nullableInteger = JSONValue.object([
        "type": .array([.string("integer"), .string("null")])
    ])

    static func array(of element: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": element])
    }

    static func object(
        _ properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.sorted().map(JSONValue.string)),
        ])
    }

    /// A listing, described by its wrapper rather than its rows.
    ///
    /// The rows vary: `fields` projects them to whatever the caller asked for,
    /// so promising their keys here would be promising something the tool is
    /// allowed to break. That the array is there under this name does not vary.
    static func listing(_ name: String) -> JSONValue {
        object([name: array(of: .object(["type": .string("object")]))], required: [name])
    }

    /// What every wait answers with, beyond its own fields.
    static let waitFields: [String: JSONValue] = [
        "seconds": number,
        "effectiveTimeout": number,
    ]
}
