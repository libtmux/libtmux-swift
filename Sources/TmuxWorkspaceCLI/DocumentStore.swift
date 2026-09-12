import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

#if YAMLWorkspaces
    import Yams
#endif

enum Value: Codable, Sendable, Equatable {
    case object([String: Value]), array([Value]), string(String), integer(Int64), number(Double),
        bool(Bool), null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: Value].self) {
            self = .object(object)
        } else if let array = try? container.decode([Value].self) {
            self = .array(array)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? container.decode(Double.self), number.isFinite {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> Value? { object?[key] }
    var object: [String: Value]? { if case let .object(value) = self { value } else { nil } }
    var array: [Value]? { if case let .array(value) = self { value } else { nil } }
    var string: String? { if case let .string(value) = self { value } else { nil } }

    func encoded(pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct DocumentStore: Sendable {
    let context: CLIContext
    static let extensions = ["yaml", "yml", "json"]

    var globalDirectories: [URL] {
        if let root = context.environment["TMUXP_CONFIGDIR"], !root.isEmpty { return [path(root)] }
        let home = context.environment["HOME"] ?? context.directory.path
        let xdg = context.environment["XDG_CONFIG_HOME"] ?? home + "/.config"
        return [path(xdg + "/tmuxp"), path(home + "/.tmuxp")]
    }

    func path(_ text: String, relativeTo directory: URL? = nil) -> URL {
        var expanded = text
        if text == "~" || text.hasPrefix("~/") {
            expanded = (context.environment["HOME"] ?? "~") + text.dropFirst()
        }
        let base = URL(fileURLWithPath: (directory ?? context.directory).path, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL
    }

    func resolve(_ input: String) throws -> URL {
        let explicit =
            input.contains("/") || input.hasPrefix(".") || input.hasPrefix("~")
            || Self.extensions.contains((input as NSString).pathExtension)
        let candidates: [URL]
        if explicit {
            let location = path(input)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: location.path, isDirectory: &directory),
                directory.boolValue
            {
                candidates = Self.extensions.map { location.appendingPathComponent(".tmuxp." + $0) }
            } else {
                candidates = [location]
            }
        } else {
            candidates = globalDirectories.flatMap { directory in
                Self.extensions.map { directory.appendingPathComponent(input + "." + $0) }
            }
        }
        guard
            let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw CLIError("workspace_not_found", "Workspace not found: \(input)")
        }
        return found
    }

    func read(_ file: URL) throws -> Value {
        let data = try readRegularFile(file)
        let value: Value
        if file.pathExtension.lowercased() == "json" {
            value = try JSONDecoder().decode(Value.self, from: data)
        } else {
            #if YAMLWorkspaces
                let yaml = String(decoding: data, as: UTF8.self)
                var documents = try compose_all(yaml: yaml)
                guard let document = documents.next(), documents.next() == nil,
                    documents.error == nil
                else {
                    throw CLIError(
                        "document", "A workspace must contain exactly one YAML document.")
                }
                value = try YAMLDecoder().decode(Value.self, from: document)
            #else
                throw CLIError(
                    "yaml_unavailable", "Build with the YAMLWorkspaces trait to read YAML.")
            #endif
        }
        guard value.object != nil else {
            throw CLIError("document", "A workspace must be a mapping.")
        }
        return value
    }

    private func readRegularFile(_ file: URL) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CLIError("document_read", String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw CLIError("document_read", String(cString: strerror(errno)))
        }
        guard attributes.st_mode & S_IFMT == S_IFREG else {
            throw CLIError("document_type", "Workspace input must be a regular file.")
        }
        let limit = 8 * 1024 * 1024
        guard attributes.st_size <= limit else {
            throw CLIError("document_size", "Workspace exceeds the 8 MiB document limit.")
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, limit + 1 - data.count)),
            !chunk.isEmpty
        {
            data.append(chunk)
            guard data.count <= limit else {
                throw CLIError("document_size", "Workspace exceeds the 8 MiB document limit.")
            }
        }
        return data
    }

    func encode(_ value: Value, format: WorkspaceFormat) throws -> String {
        if format == .json { return try value.encoded(pretty: true) + "\n" }
        #if YAMLWorkspaces
            return try YAMLEncoder().encode(value)
        #else
            throw CLIError("yaml_unavailable", "Build with the YAMLWorkspaces trait to write YAML.")
        #endif
    }

    func save(_ value: Value, to file: URL, format: WorkspaceFormat, overwrite: Bool) throws {
        let data = Data(try encode(value, format: format).utf8)
        var template = Array(
            file.deletingLastPathComponent().appendingPathComponent(".workspace-XXXXXX").path
                .utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw CLIError("document_write", String(cString: strerror(errno)))
        }
        let temporary = String(
            decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            _ = unlink(temporary)
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw CLIError("document_write", String(cString: strerror(errno)))
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        let published = overwrite ? rename(temporary, file.path) : link(temporary, file.path)
        guard published == 0 else {
            throw CLIError("document_write", String(cString: strerror(errno)))
        }
    }

    func discover(full: Bool) -> some Sequence<Value> {
        var files = Set<URL>()
        for directory in globalDirectories {
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            {
                files.formUnion(entries.filter { Self.extensions.contains($0.pathExtension) })
            }
        }
        for ext in Self.extensions {
            let file = context.directory.appendingPathComponent(".tmuxp." + ext)
            if FileManager.default.fileExists(atPath: file.path) { files.insert(file) }
        }
        return files.sorted { $0.path < $1.path }.lazy.map { file in
            var row: [String: Value] = [
                "name": .string(file.deletingPathExtension().lastPathComponent),
                "path": .string(file.path),
                "directory": .string(file.deletingLastPathComponent().path),
            ]
            do {
                let document = try read(file)
                row["session_name"] = document["session_name"] ?? .null
                if full { row["config"] = document }
            } catch { row["error"] = .string(String(describing: error)) }
            return .object(row)
        }
    }
}
