import Foundation
import Testing

@testable import McpSwapCore

@Test func routeBindsSymlinkTextLogicalParentsResolvedParentAndTarget() throws {
    try withFileFixture { root in
        let target = root.appending(path: "dotfiles/config.json")
        try createFile(target, bytes: Data("old\n".utf8), mode: 0o640)
        let linkDirectory = root.appending(path: "home/.cursor")
        try FileManager.default.createDirectory(
            at: linkDirectory, withIntermediateDirectories: true)
        let link = linkDirectory.appending(path: "mcp.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let route = try FileRoute.capture(logical: link)

        #expect(route.logical == link.standardizedFileURL)
        #expect(route.resolved == target.standardizedFileURL)
        #expect(route.logicalNodes.contains { $0.kind == .symbolicLink && $0.link == target.path })
        #expect(route.target.mode == 0o640)
        #expect(route.target.digest == SHA256.hex(Data("old\n".utf8)))
        let expectedParent = try FileIdentity.capture(target.deletingLastPathComponent())
        #expect(route.resolvedParent == expectedParent)
    }
}

@Test func routeRejectsSameBytesOnANewInode() throws {
    try withFileFixture { root in
        let path = root.appending(path: "config.json")
        try createFile(path, bytes: Data("same\n".utf8))
        let route = try FileRoute.capture(logical: path)
        let replacement = root.appending(path: "replacement")
        try createFile(replacement, bytes: Data("same\n".utf8))
        try FileManager.default.moveItem(at: replacement, to: path, replacing: true)

        #expect(throws: SwapError.self) { try route.verify() }
    }
}

@Test func routeRejectsLogicalParentReplacement() throws {
    try withFileFixture { root in
        let parent = root.appending(path: "config")
        let path = parent.appending(path: "mcp.json")
        try createFile(path, bytes: Data("old\n".utf8))
        let route = try FileRoute.capture(logical: path)
        let moved = root.appending(path: "old-config")
        try FileManager.default.moveItem(at: parent, to: moved)
        try createFile(path, bytes: Data("old\n".utf8))

        #expect(throws: SwapError.self) { try route.verify() }
    }
}

@Test func stagingForASymlinkUsesTheResolvedTargetsFilesystem() throws {
    try withFileFixture { root in
        let targetRoot =
            FileManager.default.fileExists(atPath: "/dev/shm")
            ? URL(fileURLWithPath: "/dev/shm").appending(path: "mcp-swap-\(UUID().uuidString)")
            : root.appending(path: "target")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetRoot) }
        let target = targetRoot.appending(path: "config.json")
        try createFile(target, bytes: Data("old\n".utf8))
        let link = root.appending(path: "config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let route = try FileRoute.capture(logical: link)

        let staged = try StagedFile.create(
            directory: route.resolved.deletingLastPathComponent(),
            label: "output",
            bytes: Data("new\n".utf8),
            mode: route.target.mode
        )
        defer { try? staged.removeIfOwned() }

        #expect(staged.path.deletingLastPathComponent().path == targetRoot.standardizedFileURL.path)
    }
}

@Test func exactReplacementPreservesADestinationThatRacedInBeforeExchange() throws {
    try withFileFixture { root in
        let destination = root.appending(path: "config.json")
        try createFile(destination, bytes: Data("old\n".utf8))
        let expected = try FileRoute.capture(logical: destination)
        let staged = try StagedFile.create(
            directory: root,
            label: "output",
            bytes: Data("ours\n".utf8),
            mode: 0o600
        )
        let human = Data("human\n".utf8)

        #expect(throws: SwapError.self) {
            try replaceExact(expected, with: staged) {
                let replacement = root.appending(path: "human")
                try createFile(replacement, bytes: human)
                try FileManager.default.moveItem(at: replacement, to: destination, replacing: true)
            }
        }
        #expect(try Data(contentsOf: destination) == human)
        try? staged.removeIfOwned()
    }
}

@Test func exactReplacementRollsBackADestinationReplacedAtPublication() throws {
    try withFileFixture { root in
        let destination = root.appending(path: "config.json")
        let original = Data("original".utf8)
        let proposed = Data("proposed".utf8)
        let human = Data("human replacement".utf8)
        try original.write(to: destination)
        let expected = try FileRoute.capture(logical: destination)
        let staged = try StagedFile.create(
            directory: root, label: "config", bytes: proposed, mode: 0o600)

        #expect(throws: SwapError.self) {
            try replaceExact(
                expected,
                with: staged,
                atExchange: {
                    try human.write(to: destination, options: .atomic)
                })
        }

        #expect(try Data(contentsOf: destination) == human)
        #expect(try Data(contentsOf: staged.path) == proposed)
    }
}

@Test func absentPublicationPreservesAFileThatAppearsAtTheDestination() throws {
    try withFileFixture { root in
        let destination = root.appending(path: "backup")
        let missing = try MissingRoute.capture(logical: destination)
        let staged = try StagedFile.create(
            directory: root,
            label: "backup",
            bytes: Data("ours\n".utf8),
            mode: 0o600
        )
        let human = Data("human\n".utf8)

        #expect(throws: SwapError.self) {
            try publishAbsent(missing, from: staged) {
                try createFile(destination, bytes: human)
            }
        }
        #expect(try Data(contentsOf: destination) == human)
        try? staged.removeIfOwned()
    }
}

@Test func absentPublicationReleasesTheStageAndReturnsAVerifiableRoute() throws {
    try withFileFixture { root in
        let destination = root.appending(path: "backup")
        let missing = try MissingRoute.capture(logical: destination)
        let staged = try StagedFile.create(
            directory: root,
            label: "backup",
            bytes: Data("ours\n".utf8),
            mode: 0o640
        )

        let published = try publishAbsent(missing, from: staged)

        try published.verify()
        #expect(!FileManager.default.fileExists(atPath: staged.path.path))
        #expect(try Data(contentsOf: destination) == Data("ours\n".utf8))
        #expect(published.target.mode == 0o640)
        #expect(published.target.links == 1)
    }
}

@Test func exactReplacementReturnsTheOriginalBytesAsRecovery() throws {
    try withFileFixture { root in
        let destination = root.appending(path: "config.json")
        try createFile(destination, bytes: Data("original\n".utf8), mode: 0o640)
        let expected = try FileRoute.capture(logical: destination)
        let staged = try StagedFile.create(
            directory: root,
            label: "output",
            bytes: Data("replacement\n".utf8),
            mode: 0o640
        )

        let result = try replaceExact(expected, with: staged)

        #expect(result.recovery.bytes == Data("original\n".utf8))
        #expect(try Data(contentsOf: result.recovery.path) == Data("original\n".utf8))
        #expect(try Data(contentsOf: destination) == Data("replacement\n".utf8))
        try result.recovery.removeIfOwned()
    }
}

@Test func exactRemovalPreservesAReplacementAndTheExpectedBytes() throws {
    try withFileFixture { root in
        let destination = root.appending(path: "backup")
        try createFile(destination, bytes: Data("owned\n".utf8), mode: 0o600)
        let expected = try FileRoute.capture(logical: destination)
        let human = Data("human\n".utf8)

        #expect(throws: SwapError.self) {
            try removeExact(expected) {
                let replacement = root.appending(path: "human")
                try createFile(replacement, bytes: human)
                try FileManager.default.moveItem(
                    at: replacement, to: destination, replacing: true)
            }
        }
        #expect(try Data(contentsOf: destination) == human)
        #expect(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .contains { url in
                    (try? Data(contentsOf: url)) == Data("owned\n".utf8)
                }
        )
    }
}

@Test func cleanupDoesNotDeleteAReplacedStage() throws {
    try withFileFixture { root in
        let staged = try StagedFile.create(
            directory: root,
            label: "cleanup",
            bytes: Data("owned\n".utf8),
            mode: 0o600
        )
        let replacement = root.appending(path: "replacement")
        try createFile(replacement, bytes: Data("human\n".utf8))
        try FileManager.default.moveItem(at: replacement, to: staged.path, replacing: true)

        #expect(throws: SwapError.self) { try staged.removeIfOwned() }
        #expect(try Data(contentsOf: staged.path) == Data("human\n".utf8))
    }
}

private func withFileFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "mcp-swap-fs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func createFile(_ url: URL, bytes: Data, mode: UInt16 = 0o600) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
        FileManager.default.createFile(
            atPath: url.path, contents: bytes,
            attributes: [.posixPermissions: NSNumber(value: mode)])
    else { throw SwapError.message("could not create fixture") }
}

extension FileManager {
    fileprivate func moveItem(at source: URL, to destination: URL, replacing: Bool) throws {
        if replacing, fileExists(atPath: destination.path) { try removeItem(at: destination) }
        try moveItem(at: source, to: destination)
    }
}
