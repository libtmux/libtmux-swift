import Foundation

package struct TmuxNumericVersion: Sendable, Hashable, Comparable {
    package let major: Int
    package let minor: Int
    package let patch: Int?

    package init(major: Int, minor: Int, patch: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch ?? 0) < (rhs.major, rhs.minor, rhs.patch ?? 0)
    }
}

package struct TmuxLane: Sendable {
    package let rawTag: String
    package let numericVersion: TmuxNumericVersion
    package let suffix: String?
    package let executablePath: String
    package let peeledSourceObject: String
    package let binarySHA256: String
    package let reportedVersion: String
    package let compilerIdentity: String
}

package struct TmuxDiscoveredVersion: Sendable, Equatable {
    package let rawTag: String
    package let numericVersion: TmuxNumericVersion
    package let suffix: String?
}

package enum TmuxMatrixError: Error, Sendable, Equatable {
    case invalidEvidence(String)
    case invalidReportedVersion(String)
    case invalidTag(String)
    case laneOrderMismatch(expected: [String], actual: [String])
    case reportedVersionMismatch(tag: String, reported: String)
    case missingPeeledSourceObject(tag: String)
    case invalidPeeledSourceObject(tag: String, object: String)
    case invalidBinaryPath(tag: String, path: String)
    case binaryUnavailable(tag: String)
    case binaryHashMismatch(tag: String, expected: String, actual: String)
    case unauthenticatedSource
}

package enum TmuxCompatibility {
    package static func version(
        fromReportedVersion output: String
    ) throws -> TmuxDiscoveredVersion {
        let reported = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported.hasPrefix("tmux "), !reported.dropFirst(5).isEmpty else {
            throw TmuxMatrixError.invalidReportedVersion(reported)
        }

        let rawTag = String(reported.dropFirst(5))
        let parsed = try parseTag(rawTag)
        return TmuxDiscoveredVersion(
            rawTag: rawTag,
            numericVersion: parsed.numeric,
            suffix: parsed.suffix
        )
    }

    package static func paneFormatFields(for version: TmuxNumericVersion) -> [String] {
        var fields = ["version", "pane_id"]
        if version >= TmuxNumericVersion(major: 3, minor: 3) {
            fields.append("pane_dead_signal")
        }
        if version >= TmuxNumericVersion(major: 3, minor: 7) {
            fields.append("pane_flags")
        }
        return fields
    }

    package static func breakPaneNameArgument(
        rawTag: String,
        requestedName: String?
    ) -> String? {
        requestedName ?? (rawTag == "3.7" ? "libtmux" : nil)
    }
}

package struct TmuxMatrix: Sendable {
    package let lanes: [TmuxLane]

    package static func load(
        laneDeclarationAt declarationURL: URL,
        evidenceAt evidenceURL: URL,
        binariesAt binariesURL: URL
    ) throws -> Self {
        let decoder = JSONDecoder()
        let expectedTags: [String]
        let evidence: EvidenceManifest

        do {
            expectedTags = try decoder.decode(
                [String].self,
                from: Data(contentsOf: declarationURL)
            )
            evidence = try decoder.decode(
                EvidenceManifest.self,
                from: Data(contentsOf: evidenceURL)
            )
        } catch {
            throw TmuxMatrixError.invalidEvidence(String(describing: error))
        }

        guard evidence.documentKind == "libtmux.tmux-matrix-manifest",
            evidence.schemaVersion == 1
        else {
            throw TmuxMatrixError.invalidEvidence("unsupported manifest envelope")
        }
        guard evidence.source.isAuthenticated else {
            throw TmuxMatrixError.unauthenticatedSource
        }

        let actualTags = evidence.lanes.map(\.tag)
        guard actualTags == expectedTags else {
            throw TmuxMatrixError.laneOrderMismatch(
                expected: expectedTags,
                actual: actualTags
            )
        }

        let lanes = try evidence.lanes.map { entry in
            let version = try parseTag(entry.tag)
            guard isGitObjectID(entry.tagObject) else {
                throw TmuxMatrixError.invalidEvidence(
                    "lane \(entry.tag) has an invalid tag object"
                )
            }
            let expectedReportedVersion = "tmux \(entry.tag)"
            guard entry.reportedVersion == expectedReportedVersion else {
                throw TmuxMatrixError.reportedVersionMismatch(
                    tag: entry.tag,
                    reported: entry.reportedVersion
                )
            }
            guard let peeledSourceObject = entry.peeledSourceObject,
                !peeledSourceObject.isEmpty
            else {
                throw TmuxMatrixError.missingPeeledSourceObject(tag: entry.tag)
            }
            guard isGitObjectID(peeledSourceObject) else {
                throw TmuxMatrixError.invalidPeeledSourceObject(
                    tag: entry.tag,
                    object: peeledSourceObject
                )
            }
            guard entry.buildStatus == "passed" else {
                throw TmuxMatrixError.invalidEvidence(
                    "lane \(entry.tag) did not report a passed build"
                )
            }

            let executableURL = try resolveBinary(
                entry.binaryPath,
                tag: entry.tag,
                beneath: binariesURL
            )
            let binary: Data
            do {
                binary = try Data(contentsOf: executableURL)
            } catch {
                throw TmuxMatrixError.binaryUnavailable(tag: entry.tag)
            }
            let actualSHA256 = SHA256.hexDigest(binary)
            guard actualSHA256 == entry.binarySHA256 else {
                throw TmuxMatrixError.binaryHashMismatch(
                    tag: entry.tag,
                    expected: entry.binarySHA256,
                    actual: actualSHA256
                )
            }

            return TmuxLane(
                rawTag: entry.tag,
                numericVersion: version.numeric,
                suffix: version.suffix,
                executablePath: executableURL.path,
                peeledSourceObject: peeledSourceObject,
                binarySHA256: entry.binarySHA256,
                reportedVersion: entry.reportedVersion,
                compilerIdentity: entry.compilerIdentity
            )
        }

        return Self(lanes: lanes)
    }
}

private struct EvidenceManifest: Decodable {
    let documentKind: String
    let schemaVersion: Int
    let source: SourceEvidence
    let lanes: [LaneEvidence]
}

private struct SourceEvidence: Decodable {
    let originURL: String
    let head: String
    let initialStatus: String
    let finalStatus: String
    let initialRefsSHA256: String
    let finalRefsSHA256: String
    let initialIndexSHA256: String
    let finalIndexSHA256: String
    let sourceUnchanged: Bool

    var isAuthenticated: Bool {
        originURL == "https://github.com/tmux/tmux.git"
            && isGitObjectID(head)
            && initialStatus.isEmpty
            && finalStatus.isEmpty
            && isSHA256Evidence(initialRefsSHA256)
            && isSHA256Evidence(initialIndexSHA256)
            && initialRefsSHA256 == finalRefsSHA256
            && initialIndexSHA256 == finalIndexSHA256
            && sourceUnchanged
    }
}

private struct LaneEvidence: Decodable {
    let tag: String
    let tagObject: String
    let peeledSourceObject: String?
    let binaryPath: String
    let binarySHA256: String
    let reportedVersion: String
    let compilerIdentity: String
    let buildStatus: String
}

private func parseTag(
    _ tag: String
) throws -> (numeric: TmuxNumericVersion, suffix: String?) {
    let numericEnd = tag.firstIndex { !$0.isNumber && $0 != "." } ?? tag.endIndex
    let numericPart = tag[..<numericEnd]
    let components = numericPart.split(separator: ".")
    guard components.count == 2 || components.count == 3,
        let major = Int(components[0]),
        let minor = Int(components[1])
    else {
        throw TmuxMatrixError.invalidTag(tag)
    }

    let patch = components.count == 3 ? Int(components[2]) : nil
    if components.count == 3 && patch == nil {
        throw TmuxMatrixError.invalidTag(tag)
    }

    let suffix = numericEnd == tag.endIndex ? nil : String(tag[numericEnd...])
    guard suffix?.allSatisfy(\.isLetter) ?? true else {
        throw TmuxMatrixError.invalidTag(tag)
    }

    return (
        numeric: TmuxNumericVersion(major: major, minor: minor, patch: patch),
        suffix: suffix
    )
}

private func resolveBinary(_ path: String, tag: String, beneath root: URL) throws -> URL {
    guard !path.hasPrefix("/"),
        !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    else {
        throw TmuxMatrixError.invalidBinaryPath(tag: tag, path: path)
    }

    let standardizedRoot = root.standardizedFileURL
    let binary = standardizedRoot.appendingPathComponent(path).standardizedFileURL
    let rootPrefix =
        standardizedRoot.path.hasSuffix("/")
        ? standardizedRoot.path : standardizedRoot.path + "/"
    guard binary.path.hasPrefix(rootPrefix) else {
        throw TmuxMatrixError.invalidBinaryPath(tag: tag, path: path)
    }
    return binary
}

private func isGitObjectID(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
}

private func isSHA256Evidence(_ value: String) -> Bool {
    guard value.hasPrefix("sha256:") else {
        return false
    }
    let digest = value.dropFirst("sha256:".count).utf8
    return digest.count == 64
        && digest.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
}

private enum SHA256 {
    private static let initial: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hexDigest(_ data: Data) -> String {
        var bytes = [UInt8](data)
        let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        bytes.append(contentsOf: withUnsafeBytes(of: bitCount.bigEndian, Array.init))

        var hash = initial
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] =
                    UInt32(bytes[start]) << 24
                    | UInt32(bytes[start + 1]) << 16
                    | UInt32(bytes[start + 2]) << 8
                    | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let first =
                    rotateRight(words[index - 15], by: 7)
                    ^ rotateRight(words[index - 15], by: 18)
                    ^ (words[index - 15] >> 3)
                let second =
                    rotateRight(words[index - 2], by: 17)
                    ^ rotateRight(words[index - 2], by: 19)
                    ^ (words[index - 2] >> 10)
                words[index] =
                    words[index - 16]
                    &+ first
                    &+ words[index - 7]
                    &+ second
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]

            for index in 0..<64 {
                let upper =
                    rotateRight(e, by: 6) ^ rotateRight(e, by: 11)
                    ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ (~e & g)
                let first = h &+ upper &+ choice &+ constants[index] &+ words[index]
                let lower =
                    rotateRight(a, by: 2) ^ rotateRight(a, by: 13)
                    ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let second = lower &+ majority

                h = g
                g = f
                f = e
                e = d &+ first
                d = c
                c = b
                b = a
                a = first &+ second
            }

            hash[0] &+= a
            hash[1] &+= b
            hash[2] &+= c
            hash[3] &+= d
            hash[4] &+= e
            hash[5] &+= f
            hash[6] &+= g
            hash[7] &+= h
        }

        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        value >> count | value << (32 - count)
    }
}
