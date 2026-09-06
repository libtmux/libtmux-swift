import CMcpSwap
import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

enum FileKind: String, Codable, Sendable {
    case regular
    case directory
    case symbolicLink
    case other
}

struct FileIdentity: Codable, Equatable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let links: UInt64
    let kind: FileKind
    let digest: String?

    static func capture(_ url: URL, follow: Bool = true) throws -> FileIdentity {
        let metadata = try captureMetadata(url, follow: follow)
        let digest: String?
        if metadata.kind == .regular {
            do {
                digest = SHA256.hex(try Data(contentsOf: url, options: .mappedIfSafe))
            } catch {
                throw SwapError.message("read \(url.path): \(error)")
            }
        } else {
            digest = nil
        }
        return FileIdentity(
            device: metadata.device,
            inode: metadata.inode,
            mode: metadata.mode,
            size: metadata.size,
            modifiedSeconds: metadata.modifiedSeconds,
            modifiedNanoseconds: metadata.modifiedNanoseconds,
            links: metadata.links,
            kind: metadata.kind,
            digest: digest)
    }

    static func captureMetadata(_ url: URL, follow: Bool = true) throws -> FileIdentity {
        var value = mcp_swap_file_stat()
        let result = url.path.withCString { path in
            follow ? mcp_swap_stat(path, &value) : mcp_swap_lstat(path, &value)
        }
        guard result == 0 else { throw posixError("inspect \(url.path)") }
        let kind: FileKind =
            switch value.kind {
            case Int32(MCP_SWAP_REGULAR.rawValue): .regular
            case Int32(MCP_SWAP_DIRECTORY.rawValue): .directory
            case Int32(MCP_SWAP_SYMLINK.rawValue): .symbolicLink
            default: .other
            }
        let stableSize = kind == .regular ? value.size : 0
        let stableSeconds = kind == .regular ? value.modified_seconds : 0
        let stableNanoseconds = kind == .regular ? value.modified_nanoseconds : 0
        let stableLinks = kind == .regular ? value.links : 0
        return FileIdentity(
            device: value.device,
            inode: value.inode,
            mode: value.mode,
            size: stableSize,
            modifiedSeconds: stableSeconds,
            modifiedNanoseconds: stableNanoseconds,
            links: stableLinks,
            kind: kind,
            digest: nil
        )
    }

    static func captureDescriptor(_ descriptor: Int32, data: Data?) throws
        -> FileIdentity
    {
        var value = mcp_swap_file_stat()
        guard mcp_swap_fstat(descriptor, &value) == 0 else {
            throw posixError("inspect open file")
        }
        let kind: FileKind =
            switch value.kind {
            case Int32(MCP_SWAP_REGULAR.rawValue): .regular
            case Int32(MCP_SWAP_DIRECTORY.rawValue): .directory
            case Int32(MCP_SWAP_SYMLINK.rawValue): .symbolicLink
            default: .other
            }
        return FileIdentity(
            device: value.device,
            inode: value.inode,
            mode: value.mode,
            size: value.size,
            modifiedSeconds: value.modified_seconds,
            modifiedNanoseconds: value.modified_nanoseconds,
            links: value.links,
            kind: kind,
            digest: kind == .regular ? data.map(SHA256.hex) : nil
        )
    }

    var physicalKey: String { "\(device):\(inode)" }

    func sameMetadata(as other: FileIdentity) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode
            && size == other.size && modifiedSeconds == other.modifiedSeconds
            && modifiedNanoseconds == other.modifiedNanoseconds && links == other.links
            && kind == other.kind
    }
}

struct RouteNode: Codable, Equatable, Sendable {
    let logical: String
    let kind: FileKind
    let link: String?
    let identity: FileIdentity
}

struct FileRoute: Codable, Equatable, Sendable {
    let logical: URL
    let resolved: URL
    let logicalNodes: [RouteNode]
    let resolvedParent: FileIdentity
    let target: FileIdentity

    static func capture(logical: URL, maximumBytes: Int = 16 * 1024 * 1024) throws
        -> FileRoute
    {
        let before = try captureMetadata(logical: logical)
        guard before.target.size <= maximumBytes else {
            throw SwapError.message("\(before.logical.path) exceeds \(maximumBytes) bytes")
        }
        let (data, descriptorIdentity) = try readRegularFile(
            before.resolved, maximumBytes: maximumBytes)
        let after = try captureMetadata(logical: logical)
        guard before == after, descriptorIdentity.device == before.target.device,
            descriptorIdentity.inode == before.target.inode,
            descriptorIdentity.mode == before.target.mode,
            descriptorIdentity.size == before.target.size
        else {
            throw SwapError.message("\(before.logical.path) changed while it was read")
        }
        let target = FileIdentity(
            device: before.target.device,
            inode: before.target.inode,
            mode: before.target.mode,
            size: before.target.size,
            modifiedSeconds: before.target.modifiedSeconds,
            modifiedNanoseconds: before.target.modifiedNanoseconds,
            links: before.target.links,
            kind: before.target.kind,
            digest: SHA256.hex(data)
        )
        return FileRoute(
            logical: before.logical,
            resolved: before.resolved,
            logicalNodes: before.logicalNodes,
            resolvedParent: before.resolvedParent,
            target: target
        )
    }

    func verify(maximumBytes: Int = 16 * 1024 * 1024) throws {
        let current = try FileRoute.capture(logical: logical, maximumBytes: maximumBytes)
        guard current == self else {
            throw SwapError.message("\(logical.path) changed after it was planned")
        }
    }

    func sameTopology(as other: FileRoute) -> Bool {
        logical == other.logical && resolved == other.resolved
            && logicalNodes == other.logicalNodes && resolvedParent == other.resolvedParent
    }

    func verifyMetadataOnly() throws -> FileIdentity {
        let absolute = absoluteURL(logical)
        let nodes = try logicalRouteNodes(absolute)
        let currentResolved = absolute.resolvingSymlinksInPath().standardizedFileURL
        let parent = try FileIdentity.captureMetadata(
            currentResolved.deletingLastPathComponent())
        let currentTarget = try FileIdentity.captureMetadata(currentResolved)
        guard absolute == logical,
            currentResolved == resolved,
            nodes == logicalNodes,
            parent == resolvedParent,
            currentTarget.kind == .regular,
            currentTarget.sameMetadata(as: target)
        else {
            throw SwapError.message("\(logical.path) changed after it was planned")
        }
        return currentTarget
    }

    private static func captureMetadata(logical: URL) throws -> FileRoute {
        let absolute = absoluteURL(logical)
        let nodes = try logicalRouteNodes(absolute)
        let resolved = absolute.resolvingSymlinksInPath().standardizedFileURL
        let parent = try FileIdentity.capture(resolved.deletingLastPathComponent())
        guard parent.kind == .directory else {
            throw SwapError.message("resolved parent is not a directory: \(parent)")
        }
        let target = try FileIdentity.capture(resolved)
        guard target.kind == .regular else {
            throw SwapError.message("configuration is not a regular file: \(absolute.path)")
        }
        return FileRoute(
            logical: absolute,
            resolved: resolved,
            logicalNodes: nodes,
            resolvedParent: parent,
            target: target
        )
    }
}

struct MissingRoute: Codable, Equatable, Sendable {
    let logical: URL
    let resolved: URL
    let logicalParentNodes: [RouteNode]
    let resolvedParent: FileIdentity

    static func capture(logical: URL) throws -> MissingRoute {
        let absolute = absoluteURL(logical)
        guard !pathExistsWithoutFollowing(absolute) else {
            throw SwapError.message("destination already exists: \(absolute.path)")
        }
        let parent = absolute.deletingLastPathComponent()
        let nodes = try logicalRouteNodes(parent, includeFinalDirectory: true)
        let resolvedParentURL = parent.resolvingSymlinksInPath().standardizedFileURL
        let identity = try FileIdentity.capture(resolvedParentURL)
        guard identity.kind == .directory else {
            throw SwapError.message("destination parent is not a directory")
        }
        return MissingRoute(
            logical: absolute,
            resolved: resolvedParentURL.appending(path: absolute.lastPathComponent),
            logicalParentNodes: nodes,
            resolvedParent: identity
        )
    }

    func verify() throws {
        let current = try MissingRoute.capture(logical: logical)
        guard current == self else {
            throw SwapError.message("destination parent changed after it was planned")
        }
    }
}

struct StagedFile: Sendable {
    let path: URL
    let identity: FileIdentity
    let bytes: Data

    static func create(directory: URL, label: String, bytes: Data, mode: UInt32) throws
        -> StagedFile
    {
        let parent = directory.standardizedFileURL
        let name = ".mcp-swap-\(label)-\(UUID().uuidString.lowercased())"
        let path = parent.appending(path: name)
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let descriptor = path.path.withCString { open($0, flags, mode_t(mode)) }
        guard descriptor >= 0 else { throw posixError("create stage \(path.path)") }
        var failure: Error?
        do {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = write(
                        descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard count >= 0 else { throw posixError("write stage \(path.path)") }
                    offset += count
                }
            }
            guard fchmod(descriptor, mode_t(mode)) == 0 else {
                throw posixError("set stage mode \(path.path)")
            }
            guard fsync(descriptor) == 0 else { throw posixError("sync stage \(path.path)") }
        } catch {
            failure = error
        }
        if close(descriptor) != 0, failure == nil {
            failure = posixError("close stage \(path.path)")
        }
        if let failure {
            _ = unlink(path.path)
            throw failure
        }
        try syncDirectory(parent)
        let identity = try FileIdentity.capture(path, follow: false)
        guard identity.kind == .regular, identity.digest == SHA256.hex(bytes), identity.mode == mode
        else {
            _ = unlink(path.path)
            throw SwapError.message("stage changed while it was written: \(path.path)")
        }
        return StagedFile(path: path, identity: identity, bytes: bytes)
    }

    func verify() throws {
        let current = try FileIdentity.capture(path, follow: false)
        guard current == identity else {
            throw SwapError.message("stage changed after it was written: \(path.path)")
        }
    }

    func removeIfOwned() throws {
        guard pathExistsWithoutFollowing(path) else { return }
        let quarantine = path.deletingLastPathComponent().appending(
            path: ".mcp-swap-cleanup-\(UUID().uuidString.lowercased())"
        )
        try renameNoReplace(path, quarantine)
        let moved = try FileIdentity.capture(quarantine, follow: false)
        guard moved == identity else {
            do { try renameNoReplace(quarantine, path) } catch {}
            throw SwapError.message("cleanup retained a replaced stage: \(path.path)")
        }
        guard unlink(quarantine.path) == 0 else {
            throw posixError("remove stage \(quarantine.path)")
        }
        try syncDirectory(path.deletingLastPathComponent())
    }
}

struct ReplacementResult: Sendable {
    let current: FileRoute
    let recovery: StagedFile
}

@discardableResult
func replaceExact(
    _ expected: FileRoute,
    with staged: StagedFile,
    beforeExchange: () throws -> Void = {},
    atExchange: () throws -> Void = {}
) throws -> ReplacementResult {
    try expected.verify()
    try staged.verify()
    let originalBytes = try Data(contentsOf: expected.resolved)
    guard SHA256.hex(originalBytes) == expected.target.digest else {
        throw SwapError.message("\(expected.logical.path) changed while recovery was prepared")
    }
    try expected.verify()
    try beforeExchange()
    try expected.verify()
    try staged.verify()
    try atExchange()
    let result = staged.path.path.withCString { left in
        expected.resolved.path.withCString { right in mcp_swap_exchange(left, right) }
    }
    guard result == 0 else { throw posixError("exchange \(expected.resolved.path)") }
    let moved: FileIdentity
    do {
        moved = try FileIdentity.capture(staged.path, follow: false)
    } catch {
        throw SwapError.message(
            "destination changed during publication; recovery path could not be authenticated"
        )
    }
    guard moved == expected.target else {
        if let current = try? FileRoute.capture(logical: expected.logical),
            current.sameTopology(as: expected), current.target == staged.identity,
            (try? FileIdentity.capture(staged.path, follow: false)) == moved
        {
            let rollback = staged.path.path.withCString { left in
                expected.resolved.path.withCString { right in mcp_swap_exchange(left, right) }
            }
            if rollback == 0,
                let restored = try? FileRoute.capture(logical: expected.logical),
                restored.sameTopology(as: expected), restored.target == moved,
                (try? FileIdentity.capture(staged.path, follow: false)) == staged.identity
            {
                try syncDirectory(expected.resolved.deletingLastPathComponent())
                throw SwapError.message("destination changed during publication")
            }
        }
        throw SwapError.message(
            "destination changed during publication; recovery retained at \(staged.path.path)"
        )
    }
    let current: FileRoute
    do {
        current = try FileRoute.capture(logical: expected.logical)
    } catch {
        throw SwapError.message(
            "destination route changed during publication; recovery retained at \(staged.path.path)"
        )
    }
    guard current.sameTopology(as: expected), current.target == staged.identity else {
        guard current.resolved == expected.resolved,
            sameFileIgnoringLinkCount(current.target, staged.identity)
        else {
            throw SwapError.message(
                "destination changed during publication; recovery retained at \(staged.path.path)"
            )
        }
        let rollback = staged.path.path.withCString { left in
            expected.resolved.path.withCString { right in mcp_swap_exchange(left, right) }
        }
        if rollback != 0 {
            throw SwapError.message(
                "destination changed during publication; recovery retained at \(staged.path.path)"
            )
        }
        throw SwapError.message("destination changed during publication")
    }
    try syncDirectory(expected.resolved.deletingLastPathComponent())
    return ReplacementResult(
        current: current,
        recovery: StagedFile(path: staged.path, identity: moved, bytes: originalBytes)
    )
}

@discardableResult
func publishAbsent(
    _ expected: MissingRoute,
    from staged: StagedFile,
    beforeLink: () throws -> Void = {}
) throws -> FileRoute {
    try expected.verify()
    try staged.verify()
    try beforeLink()
    let result = staged.path.path.withCString { source in
        expected.resolved.path.withCString { destination in link(source, destination) }
    }
    guard result == 0 else { throw posixError("publish \(expected.resolved.path)") }
    do {
        let current = try FileRoute.capture(logical: expected.logical)
        guard sameFileIgnoringLinkCount(current.target, staged.identity),
            current.resolved == expected.resolved,
            current.resolvedParent == expected.resolvedParent,
            current.logicalNodes == expected.logicalParentNodes
        else {
            throw SwapError.message("destination route changed during publication")
        }
        guard unlink(staged.path.path) == 0 else { throw posixError("release stage link") }
        try syncDirectory(expected.resolved.deletingLastPathComponent())
        return try FileRoute.capture(logical: expected.logical)
    } catch {
        if let current = try? FileIdentity.capture(expected.resolved, follow: false),
            sameFileIgnoringLinkCount(current, staged.identity)
        {
            _ = unlink(expected.resolved.path)
        }
        throw error
    }
}

private func sameFileIgnoringLinkCount(_ left: FileIdentity, _ right: FileIdentity) -> Bool {
    left.device == right.device && left.inode == right.inode && left.mode == right.mode
        && left.size == right.size && left.modifiedSeconds == right.modifiedSeconds
        && left.modifiedNanoseconds == right.modifiedNanoseconds && left.kind == right.kind
        && left.digest == right.digest
}

@discardableResult
func removeExact(_ expected: FileRoute, beforeRename: () throws -> Void = {}) throws
    -> StagedFile
{
    try expected.verify()
    let recovery = try StagedFile.create(
        directory: expected.resolved.deletingLastPathComponent(),
        label: "removal-recovery",
        bytes: try Data(contentsOf: expected.resolved),
        mode: expected.target.mode
    )
    try beforeRename()
    do {
        try expected.verify()
    } catch {
        throw SwapError.message(
            "destination changed before removal; recovery retained at \(recovery.path.path)"
        )
    }
    let quarantine = expected.resolved.deletingLastPathComponent().appending(
        path: ".mcp-swap-removed-\(UUID().uuidString.lowercased())"
    )
    do {
        try renameNoReplace(expected.resolved, quarantine)
    } catch {
        throw SwapError.message(
            "destination could not be removed; recovery retained at \(recovery.path.path): \(error)"
        )
    }
    let moved = try FileIdentity.capture(quarantine, follow: false)
    guard moved == expected.target else {
        do { try renameNoReplace(quarantine, expected.resolved) } catch {}
        throw SwapError.message(
            "destination changed during removal; recovery retained at \(recovery.path.path)"
        )
    }
    try recovery.removeIfOwned()
    try syncDirectory(expected.resolved.deletingLastPathComponent())
    return StagedFile(
        path: quarantine,
        identity: moved,
        bytes: try Data(contentsOf: quarantine)
    )
}

private func absoluteURL(_ url: URL) -> URL {
    if url.path.hasPrefix("/") { return url.standardizedFileURL }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: url.path).standardizedFileURL
}

private func logicalRouteNodes(_ logical: URL, includeFinalDirectory: Bool = false) throws
    -> [RouteNode]
{
    let components = logical.standardizedFileURL.pathComponents
    var current = URL(fileURLWithPath: "/")
    var nodes: [RouteNode] = []
    for (index, component) in components.dropFirst().enumerated() {
        current.append(path: component)
        let identity = try FileIdentity.captureMetadata(current, follow: false)
        let final = index == components.dropFirst().count - 1
        if final, identity.kind == .regular, !includeFinalDirectory { continue }
        guard identity.kind == .directory || identity.kind == .symbolicLink else {
            throw SwapError.message("route contains a non-directory: \(current.path)")
        }
        let target: String?
        if identity.kind == .symbolicLink {
            target = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        } else {
            target = nil
        }
        nodes.append(
            RouteNode(logical: current.path, kind: identity.kind, link: target, identity: identity)
        )
    }
    return nodes
}

private func readRegularFile(_ url: URL, maximumBytes: Int) throws -> (Data, FileIdentity) {
    let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw posixError("open \(url.path)") }
    defer { _ = close(descriptor) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        guard count >= 0 else { throw posixError("read \(url.path)") }
        if count == 0 { break }
        data.append(buffer, count: count)
        guard data.count <= maximumBytes else {
            throw SwapError.message("\(url.path) exceeds \(maximumBytes) bytes")
        }
    }
    return (data, try FileIdentity.captureDescriptor(descriptor, data: data))
}

private func pathExistsWithoutFollowing(_ url: URL) -> Bool {
    var value = mcp_swap_file_stat()
    return url.path.withCString { mcp_swap_lstat($0, &value) } == 0
}

private func renameNoReplace(_ source: URL, _ destination: URL) throws {
    let result = source.path.withCString { from in
        destination.path.withCString { to in mcp_swap_rename_noreplace(from, to) }
    }
    guard result == 0 else {
        throw posixError("move \(source.path) to \(destination.path) without replacement")
    }
}

private func syncDirectory(_ url: URL) throws {
    let result = url.path.withCString(mcp_swap_sync_directory)
    guard result == 0 else { throw posixError("sync directory \(url.path)") }
}

private func posixError(_ operation: String) -> SwapError {
    SwapError.message("\(operation): \(String(cString: strerror(errno)))")
}

enum SHA256 {
    private static let constants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
        0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
        0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
        0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
        0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
        0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    static func hex(_ data: Data) -> String {
        var bytes = [UInt8](data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes += withUnsafeBytes(of: bitLength.bigEndian, Array.init)
        var hash: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]
        for block in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = block + index * 4
                words[index] =
                    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            }
            for index in 16..<64 {
                let x = words[index - 15]
                let y = words[index - 2]
                let s0 = rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)
                let s1 = rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var work = hash
            for index in 0..<64 {
                let s1 = rotate(work[4], 6) ^ rotate(work[4], 11) ^ rotate(work[4], 25)
                let choose = (work[4] & work[5]) ^ (~work[4] & work[6])
                let temporary1 = work[7] &+ s1 &+ choose &+ constants[index] &+ words[index]
                let s0 = rotate(work[0], 2) ^ rotate(work[0], 13) ^ rotate(work[0], 22)
                let majority = (work[0] & work[1]) ^ (work[0] & work[2]) ^ (work[1] & work[2])
                let temporary2 = s0 &+ majority
                work = [
                    temporary1 &+ temporary2, work[0], work[1], work[2],
                    work[3] &+ temporary1, work[4], work[5], work[6],
                ]
            }
            for index in hash.indices { hash[index] &+= work[index] }
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        value >> amount | value << (32 - amount)
    }
}
