import Foundation
import Testing

@testable import LibTmux

/// The capability table, the manifest written from it, and the names the
/// manifest uses.
@Suite("capability registry")
struct CapabilityRegistryTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("the committed capabilities.json is what the table produces")
    func committedManifestIsTheRegistry() throws {
        let path = Self.root.appendingPathComponent("capabilities.json")
        let expected = try Support.Capabilities.manifest()
        // LIBTMUX_EMIT_CAPABILITIES=1 rewrites the file instead of comparing.
        if ProcessInfo.processInfo.environment["LIBTMUX_EMIT_CAPABILITIES"] != nil {
            try expected.write(to: path, atomically: true, encoding: .utf8)
            return
        }
        let committed = try String(contentsOf: path, encoding: .utf8)
        #expect(
            committed == expected,
            "capabilities.json drifted from the table; rerun with LIBTMUX_EMIT_CAPABILITIES=1")
    }

    @Test("ids are unique kebab-case and every version is spelled as tmux prints it")
    func idsAndVersions() {
        let ids =
            Support.Capabilities.capabilities.map(\.id)
            + Support.Capabilities.workarounds.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.wholeMatch(of: /[a-z][a-z0-9]*(-[a-z0-9]+)*/) != nil, Comment(rawValue: id))
        }
        let spellings =
            Support.Capabilities.capabilities.flatMap { [$0.since] + $0.except }
            + Support.Capabilities.workarounds.flatMap { $0.releases + [$0.fixedIn] }
        for spelling in spellings {
            #expect(
                TmuxVersion(parsing: spelling).map { "\($0)" } == spelling,
                Comment(rawValue: spelling))
        }
        for capability in Support.Capabilities.capabilities where capability.handling == .refuse {
            #expect(capability.error != nil, Comment(rawValue: capability.id))
        }
    }

    @Test("a workaround covers its own releases and no patch letter")
    func workaroundAffects() {
        let broken = Support.Capabilities.workaround("break-pane-misnames-windows")
        #expect(broken.affects(TmuxVersion(major: 3, minor: 7)))
        for spelling in ["3.6b", "3.7a", "3.7-rc2", "next-3.7", "3.8"] {
            #expect(!broken.affects(TmuxVersion(parsing: spelling)!), Comment(rawValue: spelling))
        }
    }

    @Test("every API name resolves to a declaration in the sources")
    func apiNamesResolve() throws {
        let sources = Self.root.appendingPathComponent("Sources/LibTmux")
        var text = ""
        for case let file as URL in try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        where file.pathExtension == "swift" {
            text += try String(contentsOf: file, encoding: .utf8)
        }
        let names =
            Support.Capabilities.capabilities.flatMap { $0.apis + [$0.error].compactMap { $0 } }
            + Support.Capabilities.workarounds.flatMap(\.apis)
        for name in names {
            #expect(Self.declares(name, in: text), Comment(rawValue: name))
        }
        #expect(!Self.declares("Server.noSuchMethod(named:)", in: text))
        #expect(!Self.declares("NoSuchType.run(_:)", in: text))
    }

    /// Whether `name`, spelled `Type.member(first:...)`, is declared: the type
    /// exists, and the member is a function whose first label matches or a
    /// case.
    private static func declares(_ name: String, in text: String) -> Bool {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else { return false }
        let path = name[..<open].split(separator: ".").map(String.init)
        guard path.count >= 2 else { return false }
        let labels = name[name.index(after: open)..<name.index(before: name.endIndex)]
            .split(separator: ":").map(String.init)
        let owner = NSRegularExpression.escapedPattern(for: path[path.count - 2])
        guard text.contains(try! Regex("(struct|class|enum|actor|extension) \(owner)\\b")) else {
            return false
        }
        let member = NSRegularExpression.escapedPattern(for: path[path.count - 1])
        if text.contains(try! Regex("case \(member)\\(")) { return true }
        let first = labels.first.map { NSRegularExpression.escapedPattern(for: $0) }
        let argument = first.map { $0 == "_" ? "_" : "\($0)\\b" } ?? "\\)"
        return text.contains(
            try! Regex("func \(member)(<[^>]*>)?\\(\\s*\(argument)"))
    }
}
