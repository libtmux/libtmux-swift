import Foundation

enum ToolSchemaValidationError: Error, CustomStringConvertible {
    case invalid(path: String, expectation: String)

    var description: String {
        switch self {
        case let .invalid(path, expectation):
            "\(path) must be \(expectation)"
        }
    }
}

/// The executable subset of JSON Schema emitted by the capability registry.
enum ToolSchemaValidator {
    static func validate(
        _ value: JSONValue,
        against schema: JSONValue,
        at path: String = "$"
    ) throws {
        guard let members = schema.objectValue else {
            throw ToolSchemaValidationError.invalid(
                path: path,
                expectation: "described by an object schema"
            )
        }

        if let prohibited = members["not"] {
            if (try? validate(value, against: prohibited, at: path)) != nil {
                throw ToolSchemaValidationError.invalid(path: path, expectation: "permitted")
            }
        }

        if let alternatives = members["oneOf"]?.arrayValue {
            let matches = alternatives.reduce(into: 0) { count, alternative in
                if (try? validate(value, against: alternative, at: path)) != nil {
                    count += 1
                }
            }
            guard matches == 1 else {
                throw ToolSchemaValidationError.invalid(
                    path: path,
                    expectation: "exactly one declared alternative"
                )
            }
        }

        if let constant = members["const"], value != constant {
            throw ToolSchemaValidationError.invalid(path: path, expectation: "the declared value")
        }
        if let allowed = members["enum"]?.arrayValue, !allowed.contains(value) {
            throw ToolSchemaValidationError.invalid(path: path, expectation: "an allowed value")
        }

        if let declaredTypes = schemaTypes(members["type"]),
            !declaredTypes.contains(where: { matchesType(value, $0) })
        {
            throw ToolSchemaValidationError.invalid(
                path: path,
                expectation: declaredTypes.sorted().joined(separator: " or ")
            )
        }

        if let object = value.objectValue {
            try validateObject(object, members: members, path: path)
        }
        if let array = value.arrayValue {
            try validateArray(array, members: members, path: path)
        }
        if let string = value.stringValue {
            try validateString(string, members: members, path: path)
        }
        if let number = value.doubleValue {
            try validateNumber(number, members: members, path: path)
        }
    }

    private static func schemaTypes(_ value: JSONValue?) -> [String]? {
        if let one = value?.stringValue { return [one] }
        if let many = value?.arrayValue { return many.compactMap(\.stringValue) }
        return nil
    }

    private static func matchesType(_ value: JSONValue, _ type: String) -> Bool {
        switch type {
        case "null": value.isNull
        case "boolean": value.boolValue != nil
        case "integer": value.intValue != nil
        case "number": value.doubleValue != nil
        case "string": value.stringValue != nil
        case "array": value.arrayValue != nil
        case "object": value.objectValue != nil
        default: false
        }
    }

    private static func validateObject(
        _ object: [String: JSONValue],
        members: [String: JSONValue],
        path: String
    ) throws {
        let required = Set(members["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if let missing = required.subtracting(object.keys).sorted().first {
            throw ToolSchemaValidationError.invalid(
                path: "\(path).\(missing)",
                expectation: "present"
            )
        }

        let properties = members["properties"]?.objectValue ?? [:]
        for (name, value) in object {
            if let property = properties[name] {
                try validate(value, against: property, at: "\(path).\(name)")
                continue
            }
            switch members["additionalProperties"] {
            case .bool(false):
                throw ToolSchemaValidationError.invalid(
                    path: "\(path).\(name)",
                    expectation: "a declared property"
                )
            case let additional? where additional.objectValue != nil:
                try validate(value, against: additional, at: "\(path).\(name)")
            default:
                break
            }
        }
    }

    private static func validateArray(
        _ array: [JSONValue],
        members: [String: JSONValue],
        path: String
    ) throws {
        if let maximum = members["maxItems"]?.intValue, array.count > maximum {
            throw ToolSchemaValidationError.invalid(
                path: path,
                expectation: "an array of at most \(maximum) entries"
            )
        }
        if let minimum = members["minItems"]?.intValue, array.count < minimum {
            throw ToolSchemaValidationError.invalid(
                path: path,
                expectation: "an array of at least \(minimum) entries"
            )
        }
        if let itemSchema = members["items"] {
            for (index, item) in array.enumerated() {
                try validate(item, against: itemSchema, at: "\(path)[\(index)]")
            }
        }
    }

    private static func validateString(
        _ string: String,
        members: [String: JSONValue],
        path: String
    ) throws {
        if let maximum = members["maxLength"]?.intValue, string.count > maximum {
            throw ToolSchemaValidationError.invalid(
                path: path,
                expectation: "at most \(maximum) characters"
            )
        }
        if let maximum = members["x-libtmux-max-utf8-bytes"]?.intValue,
            string.utf8.count > maximum
        {
            throw ToolSchemaValidationError.invalid(
                path: path,
                expectation: "at most \(maximum) UTF-8 bytes"
            )
        }
        if let pattern = members["pattern"]?.stringValue {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            guard expression.firstMatch(in: string, range: range) != nil else {
                throw ToolSchemaValidationError.invalid(
                    path: path,
                    expectation: "a string matching \(pattern)"
                )
            }
        }
    }

    private static func validateNumber(
        _ number: Double,
        members: [String: JSONValue],
        path: String
    ) throws {
        if let minimum = members["minimum"]?.doubleValue, number < minimum {
            throw ToolSchemaValidationError.invalid(
                path: path,
                expectation: "at least \(minimum)"
            )
        }
        if let maximum = members["maximum"]?.doubleValue, number > maximum {
            throw ToolSchemaValidationError.invalid(
                path: path,
                expectation: "at most \(maximum)"
            )
        }
    }
}
