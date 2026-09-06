import CMcpSwap
import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

struct RecoveryEntry: Codable, Equatable, Sendable {
    static let version = 1

    let version: Int
    let client: ClientName
    let scope: Scope
    let configPath: URL
    let backupPath: URL
    let server: String
    let action: ConfigAction
    let swappedAt: String
    let sequence: Int
    let originalMode: UInt32
    let expectedConfig: FileRoute
    let expectedBackup: FileRoute

    init(
        client: ClientName,
        scope: Scope,
        configPath: URL,
        backupPath: URL,
        server: String,
        action: ConfigAction,
        swappedAt: String,
        sequence: Int,
        originalMode: UInt32,
        expectedConfig: FileRoute,
        expectedBackup: FileRoute
    ) {
        version = Self.version
        self.client = client
        self.scope = scope
        self.configPath = configPath
        self.backupPath = backupPath
        self.server = server
        self.action = action
        self.swappedAt = swappedAt
        self.sequence = sequence
        self.originalMode = originalMode
        self.expectedConfig = expectedConfig
        self.expectedBackup = expectedBackup
    }

    var key: String { "\(client.rawValue):\(scope.rawValue)" }
}

struct RecoveryLedger: Codable, Equatable, Sendable {
    static let version = 1
    static let maximumBytes = 256 * 1024

    let version: Int
    var entries: [String: RecoveryEntry]
    private var checksum: String

    init(entries: [String: RecoveryEntry]) {
        version = Self.version
        self.entries = entries
        checksum = ""
    }

    func encoded() throws -> Data {
        try Self.validateEntries(entries)
        let checksum = try Self.checksum(version: version, entries: entries)
        let raw = RawLedger(version: version, entries: entries, checksum: checksum)
        let data = try Self.encoder.encode(raw)
        guard data.count <= Self.maximumBytes else {
            throw SwapError.message("recovery ledger exceeds \(Self.maximumBytes) bytes")
        }
        return data
    }

    static func decode(_ data: Data) throws -> RecoveryLedger {
        guard data.count <= maximumBytes else {
            throw SwapError.message("recovery ledger exceeds \(maximumBytes) bytes")
        }
        let text = try strictUTF8(data, label: "recovery ledger")
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SwapError.message("recovery ledger is not one JSON document: \(error)")
        }
        try rejectDuplicateJSONKeys(text)
        guard let root = object as? [String: Any],
            Set(root.keys) == ["version", "entries", "checksum"],
            let rawEntries = root["entries"] as? [String: Any]
        else {
            throw SwapError.message("recovery ledger has unknown or missing fields")
        }
        let allowedEntryFields: Set<String> = [
            "version", "client", "scope", "configPath", "backupPath", "server", "action",
            "swappedAt", "sequence", "originalMode", "expectedConfig", "expectedBackup",
        ]
        for (key, value) in rawEntries {
            guard let entry = value as? [String: Any], Set(entry.keys) == allowedEntryFields else {
                throw SwapError.message("recovery entry \(key) has unknown or missing fields")
            }
            try validateRouteObject(entry["expectedConfig"], label: "expectedConfig")
            try validateRouteObject(entry["expectedBackup"], label: "expectedBackup")
        }
        let raw: RawLedger
        do {
            raw = try JSONDecoder().decode(RawLedger.self, from: data)
        } catch {
            throw SwapError.message("recovery ledger is invalid: \(error)")
        }
        guard raw.version == version else {
            throw SwapError.message("unsupported recovery ledger version \(raw.version)")
        }
        try validateEntries(raw.entries)
        guard raw.checksum == (try checksum(version: raw.version, entries: raw.entries)) else {
            throw SwapError.message("recovery ledger checksum does not match")
        }
        var ledger = RecoveryLedger(entries: raw.entries)
        ledger.checksum = raw.checksum
        return ledger
    }

    private static func validateEntries(_ entries: [String: RecoveryEntry]) throws {
        var sequences = Set<Int>()
        for (key, entry) in entries {
            guard key == entry.key, entry.version == RecoveryEntry.version,
                entry.sequence >= 0, sequences.insert(entry.sequence).inserted,
                entry.scope == Scope.normalized(for: entry.client, requested: entry.scope),
                entry.configPath.path.hasPrefix("/"), entry.backupPath.path.hasPrefix("/"),
                entry.expectedConfig.logical == entry.configPath,
                entry.expectedBackup.logical == entry.backupPath,
                entry.expectedBackup.target.mode == 0o600,
                entry.originalMode <= 0o7777
            else {
                throw SwapError.message("recovery entry \(key) is inconsistent")
            }
        }
    }

    private static func validateRouteObject(_ raw: Any?, label: String) throws {
        let fields: Set<String> = [
            "logical", "resolved", "logicalNodes", "resolvedParent", "target",
        ]
        guard let route = raw as? [String: Any], Set(route.keys) == fields,
            route["logical"] is String, route["resolved"] is String,
            let nodes = route["logicalNodes"] as? [Any]
        else {
            throw SwapError.message("recovery \(label) route has unknown or missing fields")
        }
        try validateIdentityObject(route["resolvedParent"], label: "\(label).resolvedParent")
        try validateIdentityObject(route["target"], label: "\(label).target")
        for (index, rawNode) in nodes.enumerated() {
            guard let node = rawNode as? [String: Any],
                Set(node.keys) == ["logical", "kind", "identity"]
                    || Set(node.keys) == ["logical", "kind", "link", "identity"],
                node["logical"] is String,
                let kind = node["kind"] as? String,
                (kind == FileKind.symbolicLink.rawValue) == (node["link"] is String)
            else {
                throw SwapError.message(
                    "recovery \(label) route node \(index) has unknown or missing fields")
            }
            try validateIdentityObject(node["identity"], label: "\(label).logicalNodes[\(index)]")
        }
    }

    private static func validateIdentityObject(_ raw: Any?, label: String) throws {
        let required: Set<String> = [
            "device", "inode", "mode", "size", "modifiedSeconds", "modifiedNanoseconds",
            "links", "kind",
        ]
        guard let identity = raw as? [String: Any],
            Set(identity.keys) == required || Set(identity.keys) == required.union(["digest"]),
            let kind = identity["kind"] as? String,
            (kind == FileKind.regular.rawValue) == (identity["digest"] is String)
        else {
            throw SwapError.message("recovery \(label) identity has unknown or missing fields")
        }
    }

    private static func checksum(version: Int, entries: [String: RecoveryEntry]) throws -> String {
        try SHA256.hex(encoder.encode(LedgerPayload(version: version, entries: entries)))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private struct LedgerPayload: Codable {
        let version: Int
        let entries: [String: RecoveryEntry]
    }

    private struct RawLedger: Codable {
        let version: Int
        let entries: [String: RecoveryEntry]
        let checksum: String
    }
}

struct RecoverySnapshot: Sendable {
    let ledger: RecoveryLedger
    let route: FileRoute?

    func verify() throws {
        if let route {
            try route.verify(maximumBytes: RecoveryLedger.maximumBytes)
        }
    }
}

enum RecoveryStore {
    static func load(roots: Roots, strict: Bool) throws -> RecoverySnapshot {
        guard pathExists(roots.stateFile) else {
            return RecoverySnapshot(ledger: RecoveryLedger(entries: [:]), route: nil)
        }
        let route = try FileRoute.capture(
            logical: roots.stateFile, maximumBytes: RecoveryLedger.maximumBytes)
        guard
            !route.logicalNodes.contains(where: {
                $0.logical == roots.stateFile.path && $0.kind == .symbolicLink
            })
        else {
            throw SwapError.message("recovery ledger must not be a symlink")
        }
        guard route.target.mode == 0o600 else {
            throw SwapError.message("recovery ledger mode is not 0600")
        }
        let data = try Data(contentsOf: route.resolved)
        guard SHA256.hex(data) == route.target.digest else {
            throw SwapError.message("recovery ledger changed while it was read")
        }
        try route.verify(maximumBytes: RecoveryLedger.maximumBytes)
        do {
            return RecoverySnapshot(ledger: try RecoveryLedger.decode(data), route: route)
        } catch {
            if strict { throw error }
            return RecoverySnapshot(ledger: RecoveryLedger(entries: [:]), route: route)
        }
    }
}

final class TransactionLock: @unchecked Sendable {
    private static let processLock = NSLock()

    let path: URL
    let identity: FileIdentity
    let route: FileRoute
    private var descriptor: Int32
    private var held = true

    private init(path: URL, identity: FileIdentity, route: FileRoute, descriptor: Int32) {
        self.path = path
        self.identity = identity
        self.route = route
        self.descriptor = descriptor
    }

    static func acquire(roots: Roots, afterOpen: () throws -> Void = {}) throws
        -> TransactionLock
    {
        processLock.lock()
        var ownsProcessLock = true
        do {
            try FileManager.default.createDirectory(
                at: roots.stateDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: UInt16(0o700))]
            )
            let existed = pathExists(roots.lockFile)
            if existed {
                let existing = try FileIdentity.capture(roots.lockFile, follow: false)
                guard existing.kind == .regular, existing.links == 1,
                    existing.mode == 0o600, existing.size == 0
                else {
                    throw SwapError.message("swap lock is not an exclusive empty 0600 file")
                }
            }
            let flags = O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW
            let descriptor = roots.lockFile.path.withCString { open($0, flags, mode_t(0o600)) }
            guard descriptor >= 0 else { throw lockPOSIXError("open swap lock") }
            var closeDescriptor = true
            do {
                guard existed || fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw lockPOSIXError("set swap lock mode")
                }
                let descriptorIdentity = try FileIdentity.captureDescriptor(descriptor, data: nil)
                guard descriptorIdentity.kind == .regular, descriptorIdentity.links == 1,
                    descriptorIdentity.mode == 0o600, descriptorIdentity.size == 0
                else {
                    throw SwapError.message("swap lock is not an exclusive empty 0600 file")
                }
                let route = try FileRoute.capture(logical: roots.lockFile)
                guard route.target.sameMetadata(as: descriptorIdentity) else {
                    throw SwapError.message("swap lock path changed after it was opened")
                }
                try afterOpen()
                guard mcp_swap_lock_exclusive(descriptor) == 0 else {
                    throw lockPOSIXError("lock swap state")
                }
                let pathIdentity = try route.verifyMetadataOnly()
                guard pathIdentity.device == descriptorIdentity.device,
                    pathIdentity.inode == descriptorIdentity.inode,
                    pathIdentity.kind == .regular,
                    pathIdentity.links == 1,
                    pathIdentity.mode == 0o600,
                    pathIdentity.size == 0
                else {
                    throw SwapError.message("swap lock path changed after it was opened")
                }
                closeDescriptor = false
                ownsProcessLock = false
                return TransactionLock(
                    path: roots.lockFile,
                    identity: pathIdentity,
                    route: route,
                    descriptor: descriptor)
            } catch {
                if closeDescriptor { _ = close(descriptor) }
                throw error
            }
        } catch {
            if ownsProcessLock { processLock.unlock() }
            throw error
        }
    }

    func verify() throws {
        guard held, descriptor >= 0 else { throw SwapError.message("swap lock is not held") }
        let descriptorIdentity = try FileIdentity.captureDescriptor(descriptor, data: nil)
        let pathIdentity = try route.verifyMetadataOnly()
        guard descriptorIdentity.device == identity.device,
            descriptorIdentity.inode == identity.inode,
            pathIdentity.device == identity.device,
            pathIdentity.inode == identity.inode,
            pathIdentity.links == 1,
            pathIdentity.mode == 0o600,
            pathIdentity.size == 0
        else {
            throw SwapError.message("swap lock path no longer names the locked file")
        }
    }

    func release() {
        guard held else { return }
        held = false
        _ = mcp_swap_unlock(descriptor)
        _ = close(descriptor)
        descriptor = -1
        Self.processLock.unlock()
    }

    deinit { release() }
}

/// Reject transaction artifacts that already name the held lock without opening them.
/// POSIX record locks are process-associated, so opening and closing an alias here would
/// release the lock even though `TransactionLock` still owns its descriptor.
func rejectLockAliasesBeforeRead(_ paths: [URL], lock: TransactionLock) throws {
    for path in paths {
        let identity: FileIdentity
        do {
            identity = try FileIdentity.captureMetadata(path)
        } catch {
            var value = mcp_swap_file_stat()
            let result = path.path.withCString { mcp_swap_lstat($0, &value) }
            if result != 0, errno == ENOENT || errno == ENOTDIR { continue }
            throw error
        }
        guard identity.device != lock.identity.device || identity.inode != lock.identity.inode
        else {
            throw SwapError.message("transaction artifact aliases the shared lock: \(path.path)")
        }
    }
    try lock.verify()
}

private func pathExists(_ url: URL) -> Bool {
    var value = mcp_swap_file_stat()
    return url.path.withCString { mcp_swap_lstat($0, &value) } == 0
}

private func lockPOSIXError(_ operation: String) -> SwapError {
    SwapError.message("\(operation): \(String(cString: strerror(errno)))")
}
