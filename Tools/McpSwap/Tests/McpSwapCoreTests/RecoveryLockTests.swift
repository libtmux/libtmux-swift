import Foundation
import Testing

@testable import McpSwapCore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

@Test func recoveryLedgerIsBoundedChecksummedAndRejectsTrailingTokens() throws {
    let ledger = RecoveryLedger(entries: [:])
    let encoded = try ledger.encoded()
    let decoded = try RecoveryLedger.decode(encoded)
    #expect(decoded.entries.isEmpty)

    let text = String(decoding: encoded, as: UTF8.self)
    let duplicateEntries = text.replacingOccurrences(
        of: #""entries" :"#,
        with: #""entries" : {}, "entries" :"#)
    #expect(duplicateEntries != text)
    #expect(throws: SwapError.self) {
        try RecoveryLedger.decode(Data(duplicateEntries.utf8))
    }

    var tampered = encoded
    let marker = Data("\n{}".utf8)
    tampered.append(marker)
    #expect(throws: SwapError.self) { try RecoveryLedger.decode(tampered) }

    var changed = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    changed["checksum"] = String(repeating: "0", count: 64)
    #expect(throws: SwapError.self) {
        try RecoveryLedger.decode(try JSONSerialization.data(withJSONObject: changed))
    }

    #expect(throws: SwapError.self) {
        try RecoveryLedger.decode(Data(repeating: 0x20, count: RecoveryLedger.maximumBytes + 1))
    }
}

@Test func swiftRecoveryIsNamespacedWhileTheCrossPortLockIsShared() throws {
    try withRecoveryFixture { roots in
        #expect(roots.lockFile.path.hasSuffix("/libtmux-mcp-dev/swap/state.lock"))
        #expect(roots.stateFile.path.hasSuffix("/libtmux-mcp-dev/swap/swift/state.json"))
        #expect(
            roots.lockFile.deletingLastPathComponent().standardizedFileURL.path
                == roots.swapDirectory.standardizedFileURL.path)
        #expect(
            roots.stateFile.deletingLastPathComponent().standardizedFileURL.path
                == roots.stateDirectory.standardizedFileURL.path)
    }
}

@Test func recoveryLedgerRejectsMalformedUTF8AndUnknownFields() throws {
    #expect(throws: SwapError.self) {
        try RecoveryLedger.decode(Data([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x31, 0x7d]))
    }
    let ledger = RecoveryLedger(entries: [:])
    var object = try #require(
        JSONSerialization.jsonObject(with: ledger.encoded()) as? [String: Any])
    object["redirect"] = "/tmp/victim"
    #expect(throws: SwapError.self) {
        try RecoveryLedger.decode(try JSONSerialization.data(withJSONObject: object))
    }
}

@Test func recoveryLedgerRejectsUnknownNestedRouteFieldsBeforeChecksumValidation() throws {
    try withRecoveryFixture { roots in
        let config = roots.home.appending(path: "config.json")
        let backup = roots.home.appending(path: "config.json.bak.mcp-swap-swift-test")
        try FileManager.default.createDirectory(at: roots.home, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: config)
        try Data("{}".utf8).write(to: backup)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o640))],
            ofItemAtPath: config.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o600))],
            ofItemAtPath: backup.path)
        let entry = RecoveryEntry(
            client: .cursor,
            scope: .user,
            configPath: config,
            backupPath: backup,
            server: "libtmux",
            action: .added,
            swappedAt: "20260903080000",
            sequence: 0,
            originalMode: 0o640,
            expectedConfig: try FileRoute.capture(logical: config),
            expectedBackup: try FileRoute.capture(logical: backup))
        let encoded = try RecoveryLedger(entries: [entry.key: entry]).encoded()
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try #require(object["entries"] as? [String: Any])
        var rawEntry = try #require(entries[entry.key] as? [String: Any])
        var route = try #require(rawEntry["expectedConfig"] as? [String: Any])
        route["redirect"] = "/tmp/victim"
        rawEntry["expectedConfig"] = route
        entries[entry.key] = rawEntry
        object["entries"] = entries
        let tampered = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try RecoveryLedger.decode(tampered)
            Issue.record("nested recovery field was accepted")
        } catch let error as SwapError {
            #expect(error.description.contains("route has unknown or missing fields"))
        }
    }
}

@Test func recoveryStoreAuthenticatesModeAndSameBytesInode() throws {
    try withRecoveryFixture { roots in
        try FileManager.default.createDirectory(
            at: roots.stateDirectory, withIntermediateDirectories: true)
        let bytes = try RecoveryLedger(entries: [:]).encoded()
        try bytes.write(to: roots.stateFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o600))],
            ofItemAtPath: roots.stateFile.path
        )

        let snapshot = try RecoveryStore.load(roots: roots, strict: true)
        #expect(snapshot.route != nil)

        let replacement = roots.stateDirectory.appending(path: "replacement")
        try bytes.write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o600))],
            ofItemAtPath: replacement.path
        )
        try FileManager.default.removeItem(at: roots.stateFile)
        try FileManager.default.moveItem(at: replacement, to: roots.stateFile)
        #expect(throws: SwapError.self) { try snapshot.verify() }

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o644))],
            ofItemAtPath: roots.stateFile.path
        )
        #expect(throws: SwapError.self) { try RecoveryStore.load(roots: roots, strict: true) }
    }
}

@Test func transactionLockRejectsSymlinksAndHardlinks() throws {
    try withRecoveryFixture { roots in
        try FileManager.default.createDirectory(
            at: roots.stateDirectory, withIntermediateDirectories: true)
        let victim = roots.stateDirectory.appending(path: "victim")
        try Data().write(to: victim)
        try FileManager.default.createSymbolicLink(at: roots.lockFile, withDestinationURL: victim)
        #expect(throws: SwapError.self) { try TransactionLock.acquire(roots: roots) }
        try FileManager.default.removeItem(at: roots.lockFile)
        guard link(victim.path, roots.lockFile.path) == 0 else {
            throw SwapError.message("could not create hardlink fixture")
        }
        let modeBefore = try #require(
            FileManager.default.attributesOfItem(atPath: victim.path)[.posixPermissions]
                as? NSNumber
        ).uint16Value
        #expect(throws: SwapError.self) { try TransactionLock.acquire(roots: roots) }
        let modeAfter = try #require(
            FileManager.default.attributesOfItem(atPath: victim.path)[.posixPermissions]
                as? NSNumber
        ).uint16Value
        #expect(modeAfter == modeBefore)
    }
}

@Test func transactionLockRejectsPathReplacementAfterOpen() throws {
    try withRecoveryFixture { roots in
        try FileManager.default.createDirectory(
            at: roots.stateDirectory, withIntermediateDirectories: true)
        try Data().write(to: roots.lockFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o600))],
            ofItemAtPath: roots.lockFile.path
        )

        #expect(throws: SwapError.self) {
            try TransactionLock.acquire(roots: roots) {
                let replacement = roots.stateDirectory.appending(path: "replacement")
                try Data("human".utf8).write(to: replacement)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: UInt16(0o600))],
                    ofItemAtPath: replacement.path
                )
                try FileManager.default.removeItem(at: roots.lockFile)
                try FileManager.default.moveItem(at: replacement, to: roots.lockFile)
            }
        }
        #expect(try Data(contentsOf: roots.lockFile) == Data("human".utf8))
    }
}

@Test func transactionLockDescriptorStaysBoundToThePath() throws {
    try withRecoveryFixture { roots in
        let lock = try TransactionLock.acquire(roots: roots)
        defer { lock.release() }
        for _ in 0..<5 { try lock.verify() }
        #expect(lock.identity.links == 1)
        #expect(lock.identity.mode == 0o600)
    }
}

@Test func transactionLockContendsWithAnExternalPOSIXRecordLock() throws {
    try withRecoveryFixture { roots in
        try FileManager.default.createDirectory(
            at: roots.swapDirectory, withIntermediateDirectories: true)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-c",
            """
            import fcntl, os, sys, time
            descriptor = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
            os.fchmod(descriptor, 0o600)
            fcntl.lockf(descriptor, fcntl.LOCK_EX)
            print("ready", flush=True)
            time.sleep(0.2)
            os.ftruncate(descriptor, 0)
            os.write(descriptor, b"foreign-lock-token")
            os.fsync(descriptor)
            time.sleep(0.4)
            fcntl.lockf(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
            """,
            roots.lockFile.path,
        ]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let ready = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        #expect(ready == "ready\n")

        let started = Date()
        let lock = try TransactionLock.acquire(roots: roots)
        let waited = Date().timeIntervalSince(started)
        lock.release()

        #expect(waited >= 0.4)
    }
}

@Test func transactionRecordLockRemainsHeldAcrossIdentityVerification() throws {
    try withRecoveryFixture { roots in
        let lock = try TransactionLock.acquire(roots: roots)
        defer { lock.release() }
        for _ in 0..<5 { try lock.verify() }

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
            roots.lockFile.path,
        ]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        #expect(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                == "blocked\n")
    }
}

@Test func lockAliasPrecheckRejectsHardlinkedArtifactsWithoutDroppingTheRecordLock() throws {
    try withRecoveryFixture { roots in
        let lock = try TransactionLock.acquire(roots: roots)
        defer { lock.release() }
        let config = roots.home.appending(path: ".cursor/mcp.json")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = URL(fileURLWithPath: config.path + ".bak.mcp-swap-swift-test")

        for artifact in [config, backup] {
            guard link(roots.lockFile.path, artifact.path) == 0 else {
                throw SwapError.message("could not hardlink artifact to the shared lock")
            }
            #expect(throws: SwapError.self) {
                try rejectLockAliasesBeforeRead([artifact], lock: lock)
            }
            try expectExternalRecordLockContenderBlocked(roots.lockFile)
            try FileManager.default.removeItem(at: artifact)
            try lock.verify()
        }
    }
}

@Test func transactionLockRejectsALogicalParentSymlinkRetarget() throws {
    try withRecoveryFixture { roots in
        let lock = try TransactionLock.acquire(roots: roots)
        defer { lock.release() }
        let moved = roots.swapDirectory.deletingLastPathComponent().appending(path: "moved-swap")
        try FileManager.default.moveItem(at: roots.swapDirectory, to: moved)
        try FileManager.default.createSymbolicLink(
            at: roots.swapDirectory, withDestinationURL: moved)

        #expect(throws: SwapError.self) { try lock.verify() }
    }
}

private func withRecoveryFixture(_ body: (Roots) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "mcp-swap-ledger-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(
        try Roots(
            home: root.appending(path: "home"),
            configHome: root.appending(path: "config"),
            stateHome: root.appending(path: "state")
        ))
}

private func expectExternalRecordLockContenderBlocked(_ lockFile: URL) throws {
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
        lockFile.path,
    ]
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(
        String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            == "blocked\n")
}
