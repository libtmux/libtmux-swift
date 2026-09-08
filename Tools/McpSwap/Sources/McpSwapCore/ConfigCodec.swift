import Foundation
import TOML

enum ConfigAction: String, Codable, Sendable {
    case added
    case replaced
}

struct ConfigMutation {
    let bytes: Data
    let action: ConfigAction
}

struct NamedServer {
    let name: String
    let scope: Scope
    let spec: ServerSpec
}

enum ConfigCodec {
    static func validate(client: Client, bytes: Data) throws {
        let text = try strictUTF8(bytes, label: client.configPath.path)
        if client.format == .toml {
            _ = try TOMLDocument(text: text)
        } else {
            _ = try parseJSONObject(text, allowComments: client.format == .jsonc)
        }
    }

    static func readServer(
        client: Client,
        bytes: Data,
        server: String,
        repo: URL,
        scope: Scope
    ) throws -> ServerSpec? {
        let text = try strictUTF8(bytes, label: client.configPath.path)
        if client.format == .toml {
            return try TOMLDocument(text: text).server(named: server)
        }
        let root = try parseJSONObject(text, allowComments: client.format == .jsonc)
        return try serverSpec(
            from: serverEntry(
                root: root, client: client, server: server, repo: repo, scope: scope),
            dialect: client.dialect
        )
    }

    static func servers(
        client: Client,
        bytes: Data,
        repo: URL
    ) throws -> [NamedServer] {
        let text = try strictUTF8(bytes, label: client.configPath.path)
        if client.format == .toml {
            return try TOMLDocument(text: text).servers().map {
                NamedServer(name: $0.key, scope: .user, spec: $0.value)
            }.sorted { $0.name < $1.name }
        }
        let root = try parseJSONObject(text, allowComments: client.format == .jsonc)
        let scopes: [Scope] = client.name == .claude ? Scope.allCases : [.user]
        return try scopes.flatMap { scope in
            let entries = try serverMap(root: root, client: client, repo: repo, scope: scope) ?? [:]
            return try entries.keys.sorted().map { name in
                guard let spec = try serverSpec(from: entries[name], dialect: client.dialect) else {
                    throw SwapError.message("server entry disappeared while decoding")
                }
                return NamedServer(name: name, scope: scope, spec: spec)
            }
        }
    }

    static func settingServer(
        client: Client,
        bytes: Data,
        server: String,
        spec: ServerSpec,
        repo: URL,
        scope: Scope
    ) throws -> ConfigMutation {
        let text = try strictUTF8(bytes, label: client.configPath.path)
        if client.format == .toml {
            let document = try TOMLDocument(text: text)
            let action: ConfigAction =
                try document.server(named: server) == nil ? .added : .replaced
            return ConfigMutation(
                bytes: Data(try document.setting(server: server, spec: spec).utf8),
                action: action
            )
        }

        var root = try parseJSONObject(text, allowComments: client.format == .jsonc)
        let existed =
            try serverEntry(
                root: root, client: client, server: server, repo: repo, scope: scope) != nil
        if client.name == .opencode, root.isEmpty {
            root["$schema"] = "https://opencode.ai/config.json"
        }
        try setServerEntry(
            root: &root,
            client: client,
            server: server,
            repo: repo,
            scope: scope,
            entry: spec.entry(for: client.dialect)
        )
        let output: String
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output = try renderJSON(root, pretty: true) + "\n"
        } else {
            output = try mergeJSON(
                text: text, desired: root, allowComments: client.format == .jsonc)
        }
        _ = try parseJSONObject(output, allowComments: client.format == .jsonc)
        return ConfigMutation(bytes: Data(output.utf8), action: existed ? .replaced : .added)
    }
}

func strictUTF8(_ data: Data, label: String) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else {
        throw SwapError.message("\(label) is not valid UTF-8")
    }
    return text
}

private func parseJSONObject(_ text: String, allowComments: Bool) throws -> [String: Any] {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
    var parsed = text
    if allowComments {
        parsed = blankTrailingCommas(try blankComments(parsed))
    }
    guard let data = parsed.data(using: .utf8) else {
        throw SwapError.message("configuration is not valid UTF-8")
    }
    do {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw SwapError.message("configuration root must be an object")
        }
        try rejectDuplicateJSONKeys(parsed)
        return object
    } catch let error as SwapError {
        throw error
    } catch {
        throw SwapError.message("configuration is not valid JSON: \(error)")
    }
}

private func serverEntry(
    root: [String: Any],
    client: Client,
    server: String,
    repo: URL,
    scope: Scope
) throws -> Any? {
    try serverMap(root: root, client: client, repo: repo, scope: scope)?[server]
}

private func serverMap(
    root: [String: Any],
    client: Client,
    repo: URL,
    scope: Scope
) throws -> [String: Any]? {
    if client.name == .claude {
        if scope == .user {
            guard let raw = root["mcpServers"] else { return nil }
            guard let servers = raw as? [String: Any] else {
                throw SwapError.message("Claude config layout changed: mcpServers is not an object")
            }
            return servers
        }
        guard let rawProjects = root["projects"] else { return nil }
        guard let projects = rawProjects as? [String: Any] else {
            throw SwapError.message("Claude config layout changed: projects is not an object")
        }
        guard let rawProject = projects[repo.standardizedFileURL.path] else { return nil }
        guard let project = rawProject as? [String: Any] else {
            throw SwapError.message("Claude config layout changed: project is not an object")
        }
        guard let rawServers = project["mcpServers"] else { return nil }
        guard let servers = rawServers as? [String: Any] else {
            throw SwapError.message(
                "Claude config layout changed: project mcpServers is not an object")
        }
        return servers
    }
    guard let raw = root[client.container] else { return nil }
    guard let servers = raw as? [String: Any] else {
        throw SwapError.message("\(client.container) is not an object of server entries")
    }
    return servers
}

private func setServerEntry(
    root: inout [String: Any],
    client: Client,
    server: String,
    repo: URL,
    scope: Scope,
    entry: [String: Any]
) throws {
    if client.name == .claude {
        if scope == .user {
            let raw = root["mcpServers"]
            guard raw == nil || raw is [String: Any] else {
                throw SwapError.message("Claude config layout changed: mcpServers is not an object")
            }
            var servers = raw as? [String: Any] ?? [:]
            servers[server] = entry
            root["mcpServers"] = servers
            return
        }
        let rawProjects = root["projects"]
        guard rawProjects == nil || rawProjects is [String: Any] else {
            throw SwapError.message("Claude config layout changed: projects is not an object")
        }
        var projects = rawProjects as? [String: Any] ?? [:]
        let key = repo.standardizedFileURL.path
        let rawProject = projects[key]
        guard rawProject == nil || rawProject is [String: Any] else {
            throw SwapError.message("Claude config layout changed: project is not an object")
        }
        var project =
            rawProject as? [String: Any] ?? [
                "allowedTools": [Any](),
                "mcpContextUris": [Any](),
                "mcpServers": [String: Any](),
                "env": [String: Any](),
            ]
        let rawServers = project["mcpServers"]
        guard rawServers == nil || rawServers is [String: Any] else {
            throw SwapError.message(
                "Claude config layout changed: project mcpServers is not an object")
        }
        var servers = rawServers as? [String: Any] ?? [:]
        servers[server] = entry
        project["mcpServers"] = servers
        projects[key] = project
        root["projects"] = projects
        return
    }

    let raw = root[client.container]
    guard raw == nil || raw is [String: Any] else {
        throw SwapError.message("\(client.container) is not an object of server entries")
    }
    var servers = raw as? [String: Any] ?? [:]
    servers[server] = entry
    root[client.container] = servers
}

private func serverSpec(from raw: Any?, dialect: EntryDialect) throws -> ServerSpec? {
    guard let raw else { return nil }
    guard let entry = raw as? [String: Any] else {
        throw SwapError.message("server entry is not an object")
    }
    let command: String
    let arguments: [String]
    let environmentKey: String
    if dialect == .opencode {
        guard let argv = entry["command"] as? [Any], !argv.isEmpty,
            argv.allSatisfy({ $0 is String })
        else {
            throw SwapError.message("opencode command must be a nonempty string array")
        }
        command = argv[0] as! String
        arguments = argv.dropFirst().map { $0 as! String }
        environmentKey = "environment"
    } else {
        guard let value = entry["command"] as? String else {
            throw SwapError.message("server command must be a string")
        }
        command = value
        if let rawArguments = entry["args"] {
            guard let values = rawArguments as? [Any], values.allSatisfy({ $0 is String }) else {
                throw SwapError.message("server args must be a string array")
            }
            arguments = values.map { $0 as! String }
        } else {
            arguments = []
        }
        environmentKey = "env"
    }
    var environment: [String: String] = [:]
    if let rawEnvironment = entry[environmentKey] {
        guard let values = rawEnvironment as? [String: Any],
            values.values.allSatisfy({ $0 is String })
        else {
            throw SwapError.message("server \(environmentKey) must map strings to strings")
        }
        environment = values.mapValues { $0 as! String }
    }
    return ServerSpec(command: command, arguments: arguments, environment: environment)
}

// MARK: - JSONC-preserving merge

private let jsonWhitespace = Set<Character>([" ", "\t", "\n", "\r"])

private func blankComments(_ text: String) throws -> String {
    var characters = Array(text)
    var index = 0
    var inString = false
    while index < characters.count {
        let character = characters[index]
        if inString {
            if character == "\\" {
                index += 2
                continue
            }
            if character == "\"" { inString = false }
            index += 1
        } else if character == "\"" {
            inString = true
            index += 1
        } else if character == "/", index + 1 < characters.count,
            characters[index + 1] == "/"
        {
            while index < characters.count, characters[index] != "\n" {
                characters[index] = " "
                index += 1
            }
        } else if character == "/", index + 1 < characters.count,
            characters[index + 1] == "*"
        {
            var end = index + 2
            while end + 1 < characters.count,
                !(characters[end] == "*" && characters[end + 1] == "/")
            {
                end += 1
            }
            guard end + 1 < characters.count else {
                throw SwapError.message("configuration contains an unterminated block comment")
            }
            end = min(characters.count, end + 2)
            while index < end {
                if characters[index] != "\n" { characters[index] = " " }
                index += 1
            }
        } else {
            index += 1
        }
    }
    return String(characters)
}

private func blankTrailingCommas(_ text: String) -> String {
    var characters = Array(text)
    var index = 0
    var inString = false
    var lastComma: Int?
    while index < characters.count {
        let character = characters[index]
        if inString {
            if character == "\\" {
                index += 2
                continue
            }
            if character == "\"" { inString = false }
            index += 1
            continue
        }
        switch character {
        case "\"":
            inString = true
            lastComma = nil
        case ",": lastComma = index
        case "}", "]":
            if let lastComma { characters[lastComma] = " " }
            lastComma = nil
        default:
            if !jsonWhitespace.contains(character) { lastComma = nil }
        }
        index += 1
    }
    return String(characters)
}

private struct JSONMemberSpan {
    let key: String
    let start: Int
    let end: Int
    let valueStart: Int
    let valueEnd: Int
}

private struct JSONScanner {
    let characters: [Character]
    var position = 0

    mutating func skipWhitespace() {
        while position < characters.count, jsonWhitespace.contains(characters[position]) {
            position += 1
        }
    }

    mutating func readString() -> (text: String, start: Int, end: Int) {
        let start = position
        position += 1
        while position < characters.count {
            let character = characters[position]
            if character == "\\" {
                position += 2
                continue
            }
            position += 1
            if character == "\"" { break }
        }
        return (String(characters[start..<min(position, characters.count)]), start, position)
    }

    mutating func readValue() throws -> (start: Int, end: Int) {
        skipWhitespace()
        guard position < characters.count else {
            throw SwapError.message("unexpected end of JSON")
        }
        let start = position
        let character = characters[position]
        if character == "\"" {
            _ = readString()
        } else if character == "{" || character == "[" {
            readContainer()
        } else {
            while position < characters.count,
                !jsonWhitespace.contains(characters[position]),
                ![",", "}", "]"].contains(characters[position])
            {
                position += 1
            }
        }
        return (start, position)
    }

    mutating func readContainer() {
        position += 1
        var depth = 1
        while position < characters.count, depth > 0 {
            let character = characters[position]
            if character == "\"" {
                _ = readString()
                continue
            }
            if character == "{" || character == "[" { depth += 1 }
            if character == "}" || character == "]" { depth -= 1 }
            position += 1
        }
    }

    mutating func members(objectStart: Int) throws -> [JSONMemberSpan] {
        position = objectStart + 1
        var members: [JSONMemberSpan] = []
        while true {
            skipWhitespace()
            guard position < characters.count else {
                throw SwapError.message("unterminated JSON object")
            }
            if characters[position] == "}" { return members }
            if characters[position] == "," {
                position += 1
                continue
            }
            guard characters[position] == "\"" else {
                throw SwapError.message("JSON object key is not a string")
            }
            let memberStart = position
            let rawKey = readString().text
            skipWhitespace()
            guard position < characters.count, characters[position] == ":" else {
                throw SwapError.message("JSON object key has no value")
            }
            position += 1
            let value = try readValue()
            let keyValue = try JSONSerialization.jsonObject(
                with: Data(rawKey.utf8), options: .fragmentsAllowed)
            guard let key = keyValue as? String else {
                throw SwapError.message("JSON object key did not decode as a string")
            }
            members.append(
                JSONMemberSpan(
                    key: key,
                    start: memberStart,
                    end: value.end,
                    valueStart: value.start,
                    valueEnd: value.end
                ))
        }
    }
}

func rejectDuplicateJSONKeys(_ text: String) throws {
    var scanner = JSONDuplicateKeyScanner(characters: Array(text))
    try scanner.validate()
}

private struct JSONDuplicateKeyScanner {
    let characters: [Character]
    var position = 0

    mutating func validate() throws {
        skipWhitespace()
        try readValue()
        skipWhitespace()
        guard position == characters.count else {
            throw SwapError.message("unexpected trailing JSON content")
        }
    }

    private mutating func readValue() throws {
        skipWhitespace()
        guard position < characters.count else {
            throw SwapError.message("unexpected end of JSON")
        }
        switch characters[position] {
        case "{":
            try readObject()
        case "[":
            try readArray()
        case "\"":
            _ = try readString()
        default:
            while position < characters.count,
                !jsonWhitespace.contains(characters[position]),
                ![",", "}", "]"].contains(characters[position])
            {
                position += 1
            }
        }
    }

    private mutating func readObject() throws {
        position += 1
        skipWhitespace()
        var keys = Set<String>()
        if consume("}") { return }
        while true {
            guard position < characters.count, characters[position] == "\"" else {
                throw SwapError.message("JSON object key is not a string")
            }
            let raw = try readString()
            let decoded = try JSONSerialization.jsonObject(
                with: Data(raw.utf8), options: .fragmentsAllowed)
            guard let key = decoded as? String else {
                throw SwapError.message("JSON object key did not decode as a string")
            }
            guard keys.insert(key).inserted else {
                throw SwapError.message("JSON object contains duplicate key \(key)")
            }
            skipWhitespace()
            guard consume(":") else {
                throw SwapError.message("JSON object key has no value")
            }
            try readValue()
            skipWhitespace()
            if consume("}") { return }
            guard consume(",") else {
                throw SwapError.message("JSON object members are not separated by a comma")
            }
            skipWhitespace()
        }
    }

    private mutating func readArray() throws {
        position += 1
        skipWhitespace()
        if consume("]") { return }
        while true {
            try readValue()
            skipWhitespace()
            if consume("]") { return }
            guard consume(",") else {
                throw SwapError.message("JSON array values are not separated by a comma")
            }
            skipWhitespace()
        }
    }

    private mutating func readString() throws -> String {
        let start = position
        position += 1
        while position < characters.count {
            if characters[position] == "\\" {
                position += 2
                continue
            }
            position += 1
            if characters[position - 1] == "\"" {
                return String(characters[start..<position])
            }
        }
        throw SwapError.message("unterminated JSON string")
    }

    private mutating func skipWhitespace() {
        while position < characters.count, jsonWhitespace.contains(characters[position]) {
            position += 1
        }
    }

    private mutating func consume(_ expected: Character) -> Bool {
        guard position < characters.count, characters[position] == expected else { return false }
        position += 1
        return true
    }
}

private func objectSpan(in blanked: String, path: [String]) throws -> (Int, Int)? {
    let characters = Array(blanked)
    var scanner = JSONScanner(characters: characters)
    scanner.skipWhitespace()
    guard scanner.position < characters.count, characters[scanner.position] == "{" else {
        return nil
    }
    var cursor = scanner.position
    for key in path {
        var childScanner = JSONScanner(characters: characters)
        let member = try childScanner.members(objectStart: cursor).first { $0.key == key }
        guard let member, characters[member.valueStart] == "{" else { return nil }
        cursor = member.valueStart
    }
    var tail = JSONScanner(characters: characters, position: cursor)
    return try tail.readValue()
}

private struct JSONEdit {
    let start: Int
    let end: Int
    let replacement: String
}

private func nextJSONEdit(text: String, desired: [String: Any], path: [String]) throws
    -> JSONEdit?
{
    let blanked = blankTrailingCommas(try blankComments(text))
    guard let (objectStart, objectEnd) = try objectSpan(in: blanked, path: path) else {
        return nil
    }
    let blankedCharacters = Array(blanked)
    let textCharacters = Array(text)
    var scanner = JSONScanner(characters: blankedCharacters)
    let members = try scanner.members(objectStart: objectStart)
    let byKey = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0) })
    let depth = path.count + 1
    let padding = String(repeating: "  ", count: depth)

    for (key, value) in desired {
        guard let member = byKey[key] else {
            let body = try renderJSON(value, depth: depth)
            let name = try renderJSON(key, pretty: false)
            if let last = members.last {
                return JSONEdit(
                    start: last.end,
                    end: last.end,
                    replacement: ",\n\(padding)\(name): \(body)"
                )
            }
            let blankInterior = String(blankedCharacters[(objectStart + 1)..<(objectEnd - 1)])
            guard blankInterior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let interior = Array(textCharacters[(objectStart + 1)..<(objectEnd - 1)])
            var trailingWhitespace = 0
            for character in interior.reversed() {
                guard jsonWhitespace.contains(character) else { break }
                trailingWhitespace += 1
            }
            let anchor = objectEnd - 1 - trailingWhitespace
            let closing = String(repeating: "  ", count: depth - 1)
            return JSONEdit(
                start: anchor,
                end: objectEnd - 1,
                replacement: "\n\(padding)\(name): \(body)\n\(closing)"
            )
        }
        let currentText = String(blankedCharacters[member.valueStart..<member.valueEnd])
        let current = try JSONSerialization.jsonObject(
            with: Data(currentText.utf8), options: .fragmentsAllowed)
        if let desiredObject = value as? [String: Any], current is [String: Any] {
            if let nested = try nextJSONEdit(text: text, desired: desiredObject, path: path + [key])
            {
                return nested
            }
        } else if !jsonEqual(current, value) {
            return JSONEdit(
                start: member.valueStart,
                end: member.valueEnd,
                replacement: try renderJSON(value, depth: depth)
            )
        }
    }

    for (index, member) in members.enumerated() where desired[member.key] == nil {
        if index > 0 {
            return JSONEdit(start: members[index - 1].end, end: member.end, replacement: "")
        }
        let trailing = blankedCharacters[member.end..<objectEnd]
        var dropTo = member.end
        if let comma = trailing.firstIndex(where: { !jsonWhitespace.contains($0) }),
            blankedCharacters[comma] == ","
        {
            dropTo = comma + 1
        }
        return JSONEdit(start: objectStart + 1, end: dropTo, replacement: "")
    }
    return nil
}

private func mergeJSON(text: String, desired: [String: Any], allowComments: Bool) throws
    -> String
{
    var output = text
    for _ in 0..<10_000 {
        guard let edit = try nextJSONEdit(text: output, desired: desired, path: []) else {
            if !allowComments {
                _ = try parseJSONObject(output, allowComments: false)
            }
            return output
        }
        var characters = Array(output)
        characters.replaceSubrange(edit.start..<edit.end, with: Array(edit.replacement))
        output = String(characters)
    }
    throw SwapError.message("JSON merge did not converge")
}

private func jsonEqual(_ left: Any, _ right: Any) -> Bool {
    let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
    guard let leftData = try? JSONSerialization.data(withJSONObject: left, options: options),
        let rightData = try? JSONSerialization.data(withJSONObject: right, options: options)
    else { return false }
    return leftData == rightData
}

private func renderJSON(_ value: Any, depth: Int = 0, pretty: Bool) throws -> String {
    var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    let data = try JSONSerialization.data(withJSONObject: value, options: options)
    guard var text = String(data: data, encoding: .utf8) else {
        throw SwapError.message("JSON writer produced malformed UTF-8")
    }
    if depth > 0, text.contains("\n") {
        text = text.replacingOccurrences(
            of: "\n", with: "\n" + String(repeating: "  ", count: depth))
    }
    return text
}

private func renderJSON(_ value: Any, depth: Int) throws -> String {
    if let array = value as? [Any],
        array.allSatisfy({
            $0 is String || $0 is NSNumber || $0 is NSNull
        })
    {
        let inline = try renderJSON(array, pretty: false)
        if inline.count + depth * 2 <= 88 { return inline }
    }
    return try renderJSON(value, depth: depth, pretty: true)
}

// MARK: - TOML-preserving editor

private struct TOMLRoot: Decodable {
    var mcpServers: [String: TOMLServer]?

    enum CodingKeys: String, CodingKey {
        case mcpServers = "mcp_servers"
    }
}

private struct TOMLServer: Decodable {
    var command: String
    var args: [String]?
    var env: [String: String]?
}

private struct TOMLDocument {
    let text: String
    let decoded: TOMLRoot

    init(text: String) throws {
        self.text = text
        do {
            decoded = try TOMLDecoder().decode(TOMLRoot.self, from: text)
        } catch {
            throw SwapError.message("configuration is not valid TOML: \(error)")
        }
    }

    func server(named name: String) throws -> ServerSpec? {
        guard let server = decoded.mcpServers?[name] else { return nil }
        return ServerSpec(
            command: server.command,
            arguments: server.args ?? [],
            environment: server.env ?? [:]
        )
    }

    func servers() -> [String: ServerSpec] {
        (decoded.mcpServers ?? [:]).mapValues {
            ServerSpec(
                command: $0.command,
                arguments: $0.args ?? [],
                environment: $0.env ?? [:])
        }
    }

    func setting(server name: String, spec: ServerSpec) throws -> String {
        let spans = try tomlTableSpans(text)
        let serverPath = ["mcp_servers", name]
        let envPath = serverPath + ["env"]
        var output = text
        let serverSpan = spans.first { $0.path == serverPath }
        let envSpan = spans.first { $0.path == envPath }

        if let envSpan {
            output = replaceCharacters(
                in: output,
                range: envSpan.range,
                with: renderTOMLEnvironment(
                    path: envPath,
                    spec: spec,
                    headerSuffix: envSpan.headerSuffix,
                    comments: comments(in: String(Array(text)[envSpan.range]))
                )
            )
        }
        if serverSpan != nil {
            let adjusted = try tomlTableSpans(output).first { $0.path == serverPath }!
            output = replaceCharacters(
                in: output,
                range: adjusted.range,
                with: renderTOMLServer(
                    path: serverPath,
                    spec: spec,
                    headerSuffix: adjusted.headerSuffix,
                    comments: comments(in: String(Array(output)[adjusted.range])),
                    includeEnvironment: envSpan == nil && !spec.environment.isEmpty
                )
            )
        } else {
            if !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
            if !output.isEmpty, !output.hasSuffix("\n\n") { output += "\n" }
            output += renderTOMLServer(
                path: serverPath,
                spec: spec,
                headerSuffix: nil,
                comments: [],
                includeEnvironment: !spec.environment.isEmpty
            )
        }
        _ = try TOMLDocument(text: output)
        return output
    }
}

private struct TOMLTableSpan {
    let path: [String]
    let range: Range<Int>
    let headerSuffix: String?
}

private func tomlTableSpans(_ text: String) throws -> [TOMLTableSpan] {
    let characters = Array(text)
    var headers: [(path: [String], start: Int, suffix: String?)] = []
    var offset = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let value = String(line)
        if let header = try parseTOMLTableHeader(value) {
            headers.append((header.path, offset, header.suffix))
        }
        offset += value.count + 1
    }
    return headers.enumerated().map { index, header in
        TOMLTableSpan(
            path: header.path,
            range: header
                .start..<(index + 1 < headers.count ? headers[index + 1].start : characters.count),
            headerSuffix: header.suffix
        )
    }
}

private func parseTOMLTableHeader(_ line: String) throws
    -> (path: [String], suffix: String?)?
{
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let characters = Array(trimmed)
    guard characters.first == "[" else { return nil }
    let isArray = characters.count > 1 && characters[1] == "["
    let openingCount = isArray ? 2 : 1
    var index = openingCount
    var quote: Character?
    var escaping = false
    while index < characters.count {
        let character = characters[index]
        if escaping {
            escaping = false
        } else if quote == "\"", character == "\\" {
            escaping = true
        } else if let active = quote {
            if character == active { quote = nil }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == "]",
            !isArray || index + 1 < characters.count && characters[index + 1] == "]"
        {
            let end = index + openingCount
            let suffix = String(characters[end...])
            let remainder = suffix.trimmingCharacters(in: .whitespaces)
            guard remainder.isEmpty || remainder.hasPrefix("#") else { return nil }
            let body = String(characters[openingCount..<index])
            return (try parseTOMLKeyPath(body), suffix.isEmpty ? nil : suffix)
        }
        index += 1
    }
    return nil
}

private func parseTOMLKeyPath(_ raw: String) throws -> [String] {
    var result: [String] = []
    var token = ""
    var quote: Character?
    var escaping = false
    func finish() throws {
        let value = token.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { throw SwapError.message("empty TOML key") }
        result.append(value)
        token = ""
    }
    for character in raw {
        if escaping {
            token.append(character)
            escaping = false
        } else if quote == "\"", character == "\\" {
            escaping = true
        } else if let active = quote {
            if character == active { quote = nil } else { token.append(character) }
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == "." {
            try finish()
        } else {
            token.append(character)
        }
    }
    guard quote == nil, !escaping else { throw SwapError.message("unterminated TOML key") }
    try finish()
    return result
}

private func tomlKey(_ value: String) -> String {
    let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
    if !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) { return value }
    return tomlString(value)
}

private func tomlString(_ value: String) -> String {
    var output = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22: output += "\\\""
        case 0x5c: output += "\\\\"
        case 0x08: output += "\\b"
        case 0x09: output += "\\t"
        case 0x0a: output += "\\n"
        case 0x0c: output += "\\f"
        case 0x0d: output += "\\r"
        case 0..<0x20, 0x7f: output += String(format: "\\u%04X", scalar.value)
        default: output.unicodeScalars.append(scalar)
        }
    }
    return output + "\""
}

private func comments(in section: String) -> [String] {
    section.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
        let value = String(line)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return (trimmed.hasPrefix("#") || trimmed.isEmpty) ? value : nil
    }
}

private func renderTOMLServer(
    path: [String],
    spec: ServerSpec,
    headerSuffix: String?,
    comments: [String],
    includeEnvironment: Bool
) -> String {
    var lines = ["[\(path.map(tomlKey).joined(separator: "."))]\(headerSuffix ?? "")"]
    lines += comments.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    lines.append("command = \(tomlString(spec.command))")
    lines.append("args = [\(spec.arguments.map(tomlString).joined(separator: ", "))]")
    if includeEnvironment {
        lines.append("")
        lines.append("[\((path + ["env"]).map(tomlKey).joined(separator: "."))]")
        for key in spec.environment.keys.sorted() {
            lines.append("\(tomlKey(key)) = \(tomlString(spec.environment[key]!))")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

private func renderTOMLEnvironment(
    path: [String], spec: ServerSpec, headerSuffix: String?, comments: [String]
)
    -> String
{
    guard !spec.environment.isEmpty else { return "" }
    var lines = ["[\(path.map(tomlKey).joined(separator: "."))]\(headerSuffix ?? "")"]
    lines += comments.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    for key in spec.environment.keys.sorted() {
        lines.append("\(tomlKey(key)) = \(tomlString(spec.environment[key]!))")
    }
    return lines.joined(separator: "\n") + "\n"
}

private func replaceCharacters(in text: String, range: Range<Int>, with replacement: String)
    -> String
{
    var characters = Array(text)
    characters.replaceSubrange(range, with: Array(replacement))
    return String(characters)
}
