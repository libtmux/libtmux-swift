import Foundation
import Testing

@testable import McpSwapCore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

@Test func allEightClientsSwapPreflightAndRoundTripWithoutLosingBytes() throws {
    try withEngineFixture { fixture in
        let originals = try fixture.installAllConfigs()
        var probes: [(ClientName, Scope, ServerSpec)] = []
        let engine = fixture.engine { client, scope, spec in
            probes.append((client, scope, spec))
        }

        let report = try engine.use(
            UseRequest(
                repo: fixture.repo,
                flavor: .installed,
                environment: ["LIBTMUX_SOCKET": "test-socket"],
                clients: ClientName.allCases,
                noPreflight: false
            )
        )

        #expect(report.changes.count == 8)
        #expect(Set(probes.map(\.0)) == Set(ClientName.allCases))
        #expect(probes.allSatisfy { $0.2.environment["LIBTMUX_SOCKET"] == "test-socket" })
        let snapshot = try RecoveryStore.load(roots: fixture.roots, strict: true)
        #expect(snapshot.ledger.entries.count == 8)
        for client in knownClients(roots: fixture.roots) {
            let bytes = try Data(contentsOf: client.configPath)
            let scope = Scope.normalized(for: client.name, requested: nil)
            let spec = try ConfigCodec.readServer(
                client: client,
                bytes: bytes,
                server: "libtmux",
                repo: fixture.repo,
                scope: scope
            )
            #expect(spec?.command == "libtmux-mcp")
        }

        let reverted = try engine.revert(RevertRequest(clients: ClientName.allCases))

        #expect(reverted.changes.count == 8)
        for client in knownClients(roots: fixture.roots) {
            #expect(try Data(contentsOf: client.configPath) == originals[client.name])
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.roots.stateFile.path))
        #expect(try fixture.backups().isEmpty)
    }
}

@Test func claudeScopesUseIndependentLIFORecoveryAndRepeatKeepsTheOriginal() throws {
    try withEngineFixture { fixture in
        let claude = fixture.client(.claude)
        let original = Data(
            #"{"mcpServers":{"keep":{"command":"keep"}},"projects":{}}"#.utf8)
        try fixture.write(original, to: claude.configPath, mode: 0o640)
        let engine = fixture.engine()

        _ = try engine.use(
            UseRequest(
                repo: fixture.repo,
                flavor: .installed,
                environment: ["LAYER": "project-1"],
                clients: [.claude],
                scope: .project,
                noPreflight: true
            )
        )
        _ = try engine.use(
            UseRequest(
                repo: fixture.repo,
                flavor: .installed,
                environment: ["LAYER": "user"],
                clients: [.claude],
                scope: .user,
                noPreflight: true
            )
        )
        let beforeRepeat = try RecoveryStore.load(roots: fixture.roots, strict: true).ledger
        _ = try engine.use(
            UseRequest(
                repo: fixture.repo,
                flavor: .installed,
                environment: ["LAYER": "project-2"],
                clients: [.claude],
                scope: .project,
                noPreflight: true
            )
        )
        let afterRepeat = try RecoveryStore.load(roots: fixture.roots, strict: true).ledger

        #expect(
            beforeRepeat.entries["claude:project"]?.backupPath
                == afterRepeat.entries["claude:project"]?.backupPath)
        #expect(
            beforeRepeat.entries["claude:project"]?.sequence
                == afterRepeat.entries["claude:project"]?.sequence)
        #expect(throws: SwapError.self) {
            try engine.revert(RevertRequest(clients: [.claude], scope: .project))
        }

        _ = try engine.revert(RevertRequest(clients: [.claude], scope: .user))
        let afterUser = try Data(contentsOf: claude.configPath)
        #expect(
            try ConfigCodec.readServer(
                client: claude,
                bytes: afterUser,
                server: "libtmux",
                repo: fixture.repo,
                scope: .project
            )?.environment["LAYER"] == "project-2")
        _ = try engine.revert(RevertRequest(clients: [.claude], scope: .project))
        #expect(try Data(contentsOf: claude.configPath) == original)
        #expect(try fixture.mode(of: claude.configPath) == 0o640)
    }
}

@Test func claudeDefaultsToProjectAndUnscopedRevertUnwindsBothLayers() throws {
    try withEngineFixture { fixture in
        let claude = fixture.client(.claude)
        let original = Data(#"{"mcpServers":{},"projects":{}}"#.utf8)
        try fixture.write(original, to: claude.configPath)
        let engine = fixture.engine()

        _ = try engine.use(
            UseRequest(
                repo: fixture.repo,
                flavor: .installed,
                environment: ["LAYER": "project"],
                clients: [.claude],
                noPreflight: true))
        let projectBytes = try Data(contentsOf: claude.configPath)
        #expect(
            try ConfigCodec.readServer(
                client: claude, bytes: projectBytes, server: "libtmux", repo: fixture.repo,
                scope: .project)?.environment["LAYER"] == "project")
        #expect(
            try ConfigCodec.readServer(
                client: claude, bytes: projectBytes, server: "libtmux", repo: fixture.repo,
                scope: .user) == nil)

        _ = try engine.use(
            UseRequest(
                repo: fixture.repo,
                flavor: .installed,
                environment: ["LAYER": "user"],
                clients: [.claude],
                scope: .user,
                noPreflight: true))
        #expect(
            Set(try engine.validatedRecoveryLedger().entries.keys)
                == ["claude:project", "claude:user"])

        let report = try engine.revert(RevertRequest(clients: [.claude]))
        #expect(report.changes.map(\.label) == ["claude:user", "claude:project"])
        #expect(try Data(contentsOf: claude.configPath) == original)
        #expect(try engine.validatedRecoveryLedger().entries.isEmpty)
    }
}

@Test func malformedLaterConfigMakesTheWholeBatchObservational() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.cursor)
        let gemini = fixture.client(.gemini)
        let cursorBytes = Data(#"{"mcpServers":{}}"#.utf8)
        let malformed = Data([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x31, 0x7d])
        try fixture.write(cursorBytes, to: cursor.configPath)
        try fixture.write(malformed, to: gemini.configPath)

        #expect(throws: SwapError.self) {
            try fixture.engine().use(
                UseRequest(
                    repo: fixture.repo,
                    flavor: .installed,
                    clients: [.cursor, .gemini],
                    noPreflight: true
                )
            )
        }
        #expect(try Data(contentsOf: cursor.configPath) == cursorBytes)
        #expect(try Data(contentsOf: gemini.configPath) == malformed)
        #expect(!FileManager.default.fileExists(atPath: fixture.roots.stateFile.path))
        #expect(try fixture.backups().isEmpty)
    }
}

@Test func implicitUseAndRevertFailWhenThereIsNothingToTarget() throws {
    try withEngineFixture { fixture in
        #expect(throws: SwapError.self) {
            try fixture.engine().use(
                UseRequest(repo: fixture.repo, flavor: .installed, noPreflight: true))
        }
        #expect(throws: SwapError.self) {
            try fixture.engine().revert(RevertRequest())
        }
    }
}

@Test func retiredSafetyIsPreservedUntilTheRequestProvidesToolsets() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.cursor)
        let authorized = Data(
            #"{"mcpServers":{"libtmux":{"command":"old","env":{"LIBTMUX_SAFETY":"destructive","LIBTMUX_TOOLSETS":"inspect","KEEP":"yes"}}}}"#
                .utf8)
        try fixture.write(authorized, to: cursor.configPath)
        let engine = fixture.engine()

        _ = try engine.use(
            UseRequest(
                repo: fixture.repo, flavor: .installed, clients: [.cursor], noPreflight: true))
        let decoded = try ConfigCodec.readServer(
            client: cursor,
            bytes: Data(contentsOf: cursor.configPath),
            server: "libtmux",
            repo: fixture.repo,
            scope: .user)
        let migrated = try #require(decoded)
        #expect(
            migrated.environment == [
                "LIBTMUX_SAFETY": "destructive", "LIBTMUX_TOOLSETS": "inspect", "KEEP": "yes",
            ])

        _ = try engine.use(
            UseRequest(
                repo: fixture.repo,
                flavor: .installed,
                environment: ["LIBTMUX_TOOLSETS": "mutate"],
                clients: [.cursor],
                noPreflight: true
            ))
        let migratedValue = try ConfigCodec.readServer(
            client: cursor,
            bytes: Data(contentsOf: cursor.configPath),
            server: "libtmux",
            repo: fixture.repo,
            scope: .user)
        let explicitlyMigrated = try #require(migratedValue)
        #expect(explicitlyMigrated.environment == ["LIBTMUX_TOOLSETS": "mutate", "KEEP": "yes"])

        let gemini = fixture.client(.gemini)
        let unauthorized = Data(
            #"{"mcpServers":{"libtmux":{"command":"old","env":{"LIBTMUX_SAFETY":"readonly","KEEP":"yes"}}}}"#
                .utf8)
        try fixture.write(unauthorized, to: gemini.configPath)
        _ = try engine.use(
            UseRequest(
                repo: fixture.repo, flavor: .installed, clients: [.gemini],
                noPreflight: true))
        let preservedValue = try ConfigCodec.readServer(
            client: gemini,
            bytes: Data(contentsOf: gemini.configPath),
            server: "libtmux",
            repo: fixture.repo,
            scope: .user)
        let preserved = try #require(preservedValue)
        #expect(preserved.environment == ["LIBTMUX_SAFETY": "readonly", "KEEP": "yes"])
    }
}

@Test func revertRejectsSameBytesOnANewConfigInodeAndKeepsRecovery() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.cursor)
        try fixture.write(Data(#"{"mcpServers":{}}"#.utf8), to: cursor.configPath)
        let engine = fixture.engine()
        _ = try engine.use(
            UseRequest(
                repo: fixture.repo, flavor: .installed, clients: [.cursor], noPreflight: true)
        )
        let swapped = try Data(contentsOf: cursor.configPath)
        let replacement = cursor.configPath.deletingLastPathComponent().appending(
            path: "replacement")
        try fixture.write(swapped, to: replacement)
        try FileManager.default.removeItem(at: cursor.configPath)
        try FileManager.default.moveItem(at: replacement, to: cursor.configPath)

        #expect(throws: SwapError.self) {
            try engine.revert(RevertRequest(clients: [.cursor]))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.roots.stateFile.path))
        #expect(try fixture.backups().count == 1)
    }
}

@Test func everyOwnedArtifactIsAuthenticatedEvenForAnUnrelatedSelection() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.cursor)
        let gemini = fixture.client(.gemini)
        try fixture.write(Data(#"{"mcpServers":{}}"#.utf8), to: cursor.configPath)
        try fixture.write(Data(#"{"mcpServers":{}}"#.utf8), to: gemini.configPath)
        let engine = fixture.engine()
        _ = try engine.use(
            UseRequest(
                repo: fixture.repo, flavor: .installed, clients: [.cursor], noPreflight: true)
        )
        let backup = try #require(fixture.backups().first)
        let bytes = try Data(contentsOf: backup)
        try FileManager.default.removeItem(at: backup)
        try fixture.write(bytes, to: backup, mode: 0o600)
        let geminiBefore = try Data(contentsOf: gemini.configPath)

        #expect(throws: SwapError.self) {
            try engine.use(
                UseRequest(
                    repo: fixture.repo, flavor: .installed, clients: [.gemini], noPreflight: true)
            )
        }
        #expect(try Data(contentsOf: gemini.configPath) == geminiBefore)
    }
}

@Test func configAliasesToLockAndOwnedBackupsAreRejectedBeforeWrites() throws {
    try withEngineFixture { fixture in
        try FileManager.default.createDirectory(
            at: fixture.roots.stateDirectory, withIntermediateDirectories: true)
        try fixture.write(Data(), to: fixture.roots.lockFile, mode: 0o600)
        let cursor = fixture.client(.cursor)
        try FileManager.default.createDirectory(
            at: cursor.configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cursor.configPath, withDestinationURL: fixture.roots.lockFile)

        #expect(throws: SwapError.self) {
            try fixture.engine().use(
                UseRequest(
                    repo: fixture.repo, flavor: .installed, clients: [.cursor], noPreflight: true)
            )
        }
        #expect(try Data(contentsOf: fixture.roots.lockFile).isEmpty)
    }
}

@Test func configPublicationRaceRollsBackStateAndBackupWithoutDeletingHumanBytes() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.cursor)
        let original = Data(#"{"mcpServers":{}}"#.utf8)
        let human = Data(#"{"human":true}"#.utf8)
        try fixture.write(original, to: cursor.configPath)
        let engine = fixture.engine(commitHook: { point in
            guard case .beforeConfig(.cursor) = point else { return }
            let replacement = cursor.configPath.deletingLastPathComponent().appending(path: "human")
            try fixture.write(human, to: replacement)
            try FileManager.default.removeItem(at: cursor.configPath)
            try FileManager.default.moveItem(at: replacement, to: cursor.configPath)
        })

        #expect(throws: SwapError.self) {
            try engine.use(
                UseRequest(
                    repo: fixture.repo, flavor: .installed, clients: [.cursor], noPreflight: true)
            )
        }
        #expect(try Data(contentsOf: cursor.configPath) == human)
        #expect(!FileManager.default.fileExists(atPath: fixture.roots.stateFile.path))
        #expect(try fixture.backups().isEmpty)
    }
}

@Test func transactionKeepsTheCrossPortRecordLockThroughEveryCommitBoundary() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.cursor)
        try fixture.write(Data(#"{"mcpServers":{}}"#.utf8), to: cursor.configPath)
        var blocked: [Bool] = []
        let engine = fixture.engine(commitHook: { _ in
            blocked.append(try externalRecordLockIsBlocked(fixture.roots.lockFile))
        })

        _ = try engine.use(
            UseRequest(
                repo: fixture.repo, flavor: .installed, clients: [.cursor], noPreflight: true))

        #expect(!blocked.isEmpty)
        #expect(blocked.allSatisfy { $0 })
    }
}

@Test func dryRunDoesNotCreateLockStateBackupOrPreflight() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.cursor)
        let original = Data(#"{"mcpServers":{}}"#.utf8)
        try fixture.write(original, to: cursor.configPath)
        let engine = fixture.engine { _, _, _ in
            throw SwapError.message("dry-run attempted preflight")
        }

        let report = try engine.use(
            UseRequest(
                repo: fixture.repo,
                flavor: .installed,
                clients: [.cursor],
                dryRun: true,
                noPreflight: false
            )
        )

        #expect(report.changes.count == 1)
        #expect(try Data(contentsOf: cursor.configPath) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.roots.stateDirectory.path))
        #expect(try fixture.backups().isEmpty)
    }
}

@Test func stateAndBackupPublicationRacesPreserveTheArrivingFiles() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.cursor)
        let original = Data(#"{"mcpServers":{}}"#.utf8)
        let humanState = Data(#"{"human":"state"}"#.utf8)
        try fixture.write(original, to: cursor.configPath)
        let stateRacing = fixture.engine(commitHook: { point in
            guard case .beforeState = point else { return }
            try fixture.write(humanState, to: fixture.roots.stateFile, mode: 0o600)
        })

        #expect(throws: SwapError.self) {
            try stateRacing.use(
                UseRequest(
                    repo: fixture.repo, flavor: .installed, clients: [.cursor], noPreflight: true)
            )
        }
        #expect(try Data(contentsOf: cursor.configPath) == original)
        #expect(try Data(contentsOf: fixture.roots.stateFile) == humanState)
        #expect(try fixture.backups().isEmpty)

        try FileManager.default.removeItem(at: fixture.roots.stateFile)
        let humanBackup = Data("human backup\n".utf8)
        var racedBackup: URL?
        let backupRacing = fixture.engine(commitHook: { point in
            guard case .beforeBackupPublication(_, _, let path) = point else { return }
            racedBackup = path
            try fixture.write(humanBackup, to: path, mode: 0o600)
        })
        #expect(throws: SwapError.self) {
            try backupRacing.use(
                UseRequest(
                    repo: fixture.repo, flavor: .installed, clients: [.cursor], noPreflight: true)
            )
        }
        let backup = try #require(racedBackup)
        #expect(try Data(contentsOf: backup) == humanBackup)
        #expect(try Data(contentsOf: cursor.configPath) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.roots.stateFile.path))
    }
}

@Test func swapRejectsAnOtherwiseUnknownHardlinkWithoutMutatingItsPeer() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.cursor)
        let victim = fixture.root.appending(path: "human-config")
        let bytes = Data(#"{"mcpServers":{}}"#.utf8)
        try fixture.write(bytes, to: victim)
        try FileManager.default.createDirectory(
            at: cursor.configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard link(victim.path, cursor.configPath.path) == 0 else {
            throw SwapError.message("could not create hardlink fixture")
        }

        #expect(throws: SwapError.self) {
            try fixture.engine().use(
                UseRequest(
                    repo: fixture.repo, flavor: .installed, clients: [.cursor], noPreflight: true)
            )
        }
        #expect(try Data(contentsOf: victim) == bytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.roots.stateFile.path))
    }
}

@Test func symlinkedConfigOnAnotherFilesystemRoundTripsWithoutReplacingTheLink() throws {
    try withEngineFixture { fixture in
        let cursor = fixture.client(.pi)
        let targetRoot =
            FileManager.default.fileExists(atPath: "/dev/shm")
            ? URL(fileURLWithPath: "/dev/shm").appending(
                path: "mcp-swap-engine-\(UUID().uuidString)")
            : fixture.root.appending(path: "other-filesystem")
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetRoot) }
        let target = targetRoot.appending(path: "cursor.json")
        let original = Data("{\n  // cross-filesystem target\n  \"mcpServers\": {}\n}\n".utf8)
        try fixture.write(original, to: target, mode: 0o640)
        try FileManager.default.createDirectory(
            at: cursor.configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cursor.configPath, withDestinationURL: target)
        let linkText = try FileManager.default.destinationOfSymbolicLink(
            atPath: cursor.configPath.path)
        let engine = fixture.engine()

        _ = try engine.use(
            UseRequest(
                repo: fixture.repo, flavor: .installed, clients: [.pi], noPreflight: true))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: cursor.configPath.path)
                == linkText)
        _ = try engine.revert(RevertRequest(clients: [.pi]))

        #expect(try Data(contentsOf: target) == original)
        #expect(try fixture.mode(of: target) == 0o640)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: cursor.configPath.path)
                == linkText)
    }
}

private struct EngineFixture {
    let root: URL
    let home: URL
    let config: URL
    let state: URL
    let repo: URL
    let roots: Roots

    init(root: URL) throws {
        self.root = root
        home = root.appending(path: "home")
        config = root.appending(path: "config")
        state = root.appending(path: "state")
        repo = root.appending(path: "repo")
        roots = try Roots(home: home, configHome: config, stateHome: state)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data(
            """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(name: "fixture", products: [.executable(name: "libtmux-mcp", targets: ["Server"])], targets: [.executableTarget(name: "Server")])
            """.utf8
        ).write(to: repo.appending(path: "Package.swift"))
    }

    func client(_ name: ClientName) -> Client {
        knownClients(roots: roots).first { $0.name == name }!
    }

    func engine(
        preflight: @escaping (ClientName, Scope, ServerSpec) throws -> Void = { _, _, _ in },
        commitHook: @escaping (CommitPoint) throws -> Void = { _ in }
    ) -> SwapEngine {
        SwapEngine(
            roots: roots,
            environment: [:],
            executableLookup: { _ in URL(fileURLWithPath: "/usr/bin/swift") },
            preflightAction: preflight,
            timestamp: { "20260903080000" },
            commitHook: commitHook
        )
    }

    func installAllConfigs() throws -> [ClientName: Data] {
        var originals: [ClientName: Data] = [:]
        for client in knownClients(roots: roots) {
            let bytes: Data
            switch client.format {
            case .toml:
                bytes = Data("# keep \(client.name.rawValue)\ntitle = \"example\"\n".utf8)
            case .jsonc:
                bytes = Data("{\n  // keep \(client.name.rawValue)\n}\n".utf8)
            case .json:
                bytes = Data("{\n  \"keep\": \"\(client.name.rawValue)\"\n}\n".utf8)
            }
            try write(bytes, to: client.configPath, mode: 0o640)
            originals[client.name] = bytes
        }
        return originals
    }

    func write(_ bytes: Data, to url: URL, mode: UInt16 = 0o600) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard
            FileManager.default.createFile(
                atPath: url.path,
                contents: bytes,
                attributes: [.posixPermissions: NSNumber(value: mode)])
        else { throw SwapError.message("could not create fixture file") }
    }

    func backups() throws -> [URL] {
        try knownClients(roots: roots).flatMap { client in
            guard
                FileManager.default.fileExists(
                    atPath: client.configPath.deletingLastPathComponent().path)
            else { return [URL]() }
            return try FileManager.default.contentsOfDirectory(
                at: client.configPath.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.contains(".bak.mcp-swap-swift-") }
        }
    }

    func mode(of url: URL) throws -> UInt32 {
        try FileIdentity.capture(url).mode
    }
}

private func withEngineFixture(_ body: (EngineFixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "mcp-swap-engine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(try EngineFixture(root: root))
}

private func externalRecordLockIsBlocked(_ path: URL) throws -> Bool {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3", "-c",
        """
        import fcntl, os, sys
        descriptor = os.open(sys.argv[1], os.O_RDWR)
        try:
            fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("blocked")
        else:
            print("acquired")
        os.close(descriptor)
        """,
        path.path,
    ]
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        == "blocked\n"
}
