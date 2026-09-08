import Foundation
import Testing

@testable import McpSwapCore

@Test func catalogContainsAllEightClientsInTransactionOrder() throws {
    let root = URL(fileURLWithPath: "/tmp/mcp-swap-test-home")
    let roots = try Roots(
        home: root, configHome: root.appending(path: "config"),
        stateHome: root.appending(path: "state"))

    let clients = knownClients(roots: roots)

    #expect(
        clients.map(\.name) == [.claude, .codex, .cursor, .gemini, .grok, .agy, .opencode, .pi])
    #expect(clients.map(\.format) == [.json, .toml, .json, .json, .toml, .json, .jsonc, .jsonc])
}

@Test func clientSelectionNormalizesAliasesAndCanonicalizesEveryPermutation() throws {
    let expected = ClientName.allCases
    var values = expected
    var count = 0

    func visit(_ index: Int) throws {
        if index == values.count {
            let selectors = values.map { $0 == .agy ? "antigravity" : $0.rawValue }
            #expect(try selectClientNames(selectors) == expected)
            count += 1
            return
        }
        for candidate in index..<values.count {
            values.swapAt(index, candidate)
            try visit(index + 1)
            values.swapAt(index, candidate)
        }
    }

    try visit(0)
    #expect(count == 40_320)
}

@Test func clientSelectionRejectsUnknownNames() {
    #expect(throws: SwapError.self) {
        try selectClientNames(["claude", "not-a-client"])
    }
}

@Test func sourceModesMatchTheExistingSwiftTool() throws {
    try withTemporaryDirectory { directory in
        let repo = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try manifest(executable: "libtmux-mcp").write(
            to: repo.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let swift = directory.appending(path: "toolchain/bin/swift")
        try FileManager.default.createDirectory(
            at: swift.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: swift.path, contents: Data())
        let debug = repo.appending(path: ".build/debug/libtmux-mcp")
        let release = repo.appending(path: ".build/release/libtmux-mcp")
        for binary in [debug, release] {
            try FileManager.default.createDirectory(
                at: binary.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = FileManager.default.createFile(atPath: binary.path, contents: Data())
        }

        let metadata = try resolveRepoMetadata(repo: repo)
        #expect(metadata.server == "libtmux")
        #expect(metadata.entry == "libtmux-mcp")
        #expect(
            try buildLocalSpec(
                repo: repo,
                entry: metadata.entry,
                flavor: .dev,
                executableLookup: { $0 == "swift" ? swift : nil }
            )
                == ServerSpec(
                    command: swift.path,
                    arguments: ["run", "--package-path", repo.path, "libtmux-mcp"],
                    environment: [:]
                )
        )
        #expect(
            try buildLocalSpec(repo: repo, entry: metadata.entry, flavor: .debug).command
                == debug.path
        )
        #expect(
            try buildLocalSpec(repo: repo, entry: metadata.entry, flavor: .release).command
                == release.path
        )
        #expect(
            try buildLocalSpec(repo: repo, entry: metadata.entry, flavor: .installed)
                == ServerSpec(command: "libtmux-mcp", arguments: [], environment: [:])
        )
    }
}

@Test func legacyNestedPackageDerivesServerAndCheckoutEquivalently() throws {
    try withTemporaryDirectory { directory in
        let repo = directory.appending(path: "repo")
        let package = repo.appending(path: "swift")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try manifest(executable: "weather").write(
            to: package.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        let binary = package.appending(path: ".build/debug/weather")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: binary.path, contents: Data())

        let metadata = try resolveRepoMetadata(repo: repo)
        // Compared as paths: `standardizedFileURL` marks an existing
        // directory with a trailing slash on Darwin and not on Linux, so the
        // URLs differ where the locations do not.
        #expect(metadata.package.path == package.standardizedFileURL.path)
        #expect(metadata.server == "weather")
        #expect(metadata.entry == "weather")
        let spec = try buildLocalSpec(repo: repo, entry: metadata.entry, flavor: .debug)
        #expect(spec.localRepository?.path == repo.standardizedFileURL.path)
    }
}

@Test func prebuiltSourceRejectsEntryPathTraversal() throws {
    try withTemporaryDirectory { repo in
        try manifest(executable: "libtmux-mcp").write(
            to: repo.appending(path: "Package.swift"), atomically: true, encoding: .utf8)

        for entry in ["../outside", "nested/tool", "/tmp/tool", ".", ".."] {
            for flavor in [SourceFlavor.debug, .release] {
                do {
                    _ = try buildLocalSpec(repo: repo, entry: entry, flavor: flavor)
                    Issue.record("accepted a traversing prebuilt entry")
                } catch let error as SwapError {
                    #expect(error.description.contains("single executable name"))
                }
            }
        }
    }
}

@Test func pullRequestSourceAndRemoteNormalizationRetainCompatibility() throws {
    let cases = [
        ("git+ssh://git@github.com/o/n.git", "https://github.com/o/n"),
        ("ssh://git@github.com/o/n.git", "https://github.com/o/n"),
        ("git@github.com:o/n.git", "https://github.com/o/n"),
        ("https://github.com/o/n.git", "https://github.com/o/n"),
        ("git@git.example.com:team/n.git", "https://git.example.com/team/n"),
    ]
    for (input, expected) in cases {
        #expect(try normalizeRemoteURL(input) == expected)
    }
    #expect(
        try buildPullRequestSpec(
            repoURL: "https://github.com/o/n", number: 15, entry: "libtmux-mcp")
            == ServerSpec(
                command: "uvx",
                arguments: [
                    "--from", "git+https://github.com/o/n@refs/pull/15/head", "libtmux-mcp",
                ],
                environment: [:]
            )
    )
}

@Test func pullRequestRemoteDerivationHonorsGitURLRewrites() throws {
    try withTemporaryDirectory { repo in
        try runGit(["init", "--quiet"], in: repo)
        try runGit(["config", "url.https://github.com/.insteadOf", "gh:"], in: repo)
        try runGit(["remote", "add", "origin", "gh:owner/project.git"], in: repo)

        #expect(try gitRemoteURL(repo: repo) == "https://github.com/owner/project.git")
    }
}

private func manifest(executable: String) -> String {
    """
    // swift-tools-version: 6.2
    import PackageDescription
    let package = Package(
        name: "libtmux",
        products: [.executable(name: "\(executable)", targets: ["\(executable)"])]
    )
    """
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "mcp-swap-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory.path] + arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SwapError.message("git fixture command failed")
    }
}
