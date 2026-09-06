import Foundation

struct UseRequest: Equatable, Sendable {
    var repo: URL
    var pullRequest: Int?
    var remoteURL: String?
    var flavor: SourceFlavor
    var server: String?
    var entry: String?
    var environment: [String: String]
    var clients: [ClientName]
    var scope: Scope?
    var dryRun: Bool
    var noPreflight: Bool

    init(
        repo: URL,
        pullRequest: Int? = nil,
        remoteURL: String? = nil,
        flavor: SourceFlavor = .dev,
        server: String? = nil,
        entry: String? = nil,
        environment: [String: String] = [:],
        clients: [ClientName] = [],
        scope: Scope? = nil,
        dryRun: Bool = false,
        noPreflight: Bool = false
    ) {
        self.repo = repo
        self.pullRequest = pullRequest
        self.remoteURL = remoteURL
        self.flavor = flavor
        self.server = server
        self.entry = entry
        self.environment = environment
        self.clients = clients
        self.scope = scope
        self.dryRun = dryRun
        self.noPreflight = noPreflight
    }
}

struct RevertRequest: Equatable, Sendable {
    var clients: [ClientName]
    var scope: Scope?
    var dryRun: Bool

    init(clients: [ClientName] = [], scope: Scope? = nil, dryRun: Bool = false) {
        self.clients = clients
        self.scope = scope
        self.dryRun = dryRun
    }
}

struct OperationChange: Sendable {
    let label: String
    let path: URL
    let action: String
    let backup: URL?
    let before: Data
    let after: Data
}

struct OperationReport: Sendable {
    var changes: [OperationChange]
    var messages: [String]
    var warnings: [String]
}

enum CommitPoint: Equatable, Sendable {
    case beforeBackupPublication(ClientName, Scope, URL)
    case beforeBackupRewrite(ClientName, Scope, URL)
    case beforeState
    case beforeConfig(ClientName)
    case beforeBackupRemoval(ClientName, Scope, URL)
}

struct SwapEngine {
    let roots: Roots
    let environment: [String: String]
    let executableLookup: (String) -> URL?
    let preflightAction: (ClientName, Scope, ServerSpec) throws -> Void
    let timestamp: () -> String
    let commitHook: (CommitPoint) throws -> Void

    init(
        roots: Roots,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableLookup: @escaping (String) -> URL? = executableOnPath,
        preflightAction: @escaping (ClientName, Scope, ServerSpec) throws -> Void = {
            _, _, spec in try preflight(spec)
        },
        timestamp: @escaping () -> String = SwapEngine.currentTimestamp,
        commitHook: @escaping (CommitPoint) throws -> Void = { _ in }
    ) {
        self.roots = roots
        self.environment = environment
        self.executableLookup = executableLookup
        self.preflightAction = preflightAction
        self.timestamp = timestamp
        self.commitHook = commitHook
    }

    func use(_ request: UseRequest) throws -> OperationReport {
        guard request.environment["LIBTMUX_SAFETY"] == nil else {
            throw SwapError.message("LIBTMUX_SAFETY has been removed; use LIBTMUX_TOOLSETS")
        }
        let source = try resolveSource(request)
        let preliminary = try planUse(request, source: source, lock: nil)
        if request.dryRun { return preliminary.report }
        if !request.noPreflight {
            for plan in preliminary.plans {
                try preflightAction(plan.client.name, plan.scope, plan.spec)
            }
        }
        guard !preliminary.plans.isEmpty else { return preliminary.report }

        let lock = try TransactionLock.acquire(roots: roots)
        defer { lock.release() }
        let final = try planUse(request, source: source, lock: lock)
        if !request.noPreflight, final.fingerprint != preliminary.fingerprint {
            for plan in final.plans {
                try preflightAction(plan.client.name, plan.scope, plan.spec)
            }
        }
        guard !final.plans.isEmpty else { return final.report }
        return try commitUse(final, lock: lock)
    }

    func revert(_ request: RevertRequest) throws -> OperationReport {
        let preliminary = try planRevert(request, lock: nil)
        if request.dryRun || preliminary.plans.isEmpty { return preliminary.report }
        let lock = try TransactionLock.acquire(roots: roots)
        defer { lock.release() }
        let final = try planRevert(request, lock: lock)
        guard !final.plans.isEmpty else { return final.report }
        return try commitRevert(final, lock: lock)
    }

    func validatedRecoveryLedger() throws -> RecoveryLedger {
        let snapshot = try RecoveryStore.load(roots: roots, strict: true)
        _ = try authenticate(snapshot)
        return snapshot.ledger
    }

    private func resolveSource(_ request: UseRequest) throws -> ResolvedSource {
        let repo = request.repo.standardizedFileURL
        let metadata = try resolveRepoMetadata(repo: repo)
        let server = request.server ?? metadata.server
        let entry = request.entry ?? metadata.entry
        let spec: ServerSpec
        if let number = request.pullRequest {
            let remote = try request.remoteURL ?? gitRemoteURL(repo: repo)
            spec = try buildPullRequestSpec(
                repoURL: normalizeRemoteURL(remote), number: number, entry: entry)
        } else {
            spec = try buildLocalSpec(
                repo: repo, entry: entry, flavor: request.flavor,
                executableLookup: executableLookup)
        }
        return ResolvedSource(repo: repo, server: server, spec: spec)
    }

    private func planUse(
        _ request: UseRequest, source: ResolvedSource, lock: TransactionLock?
    ) throws -> UseTransaction {
        if let lock {
            try rejectLockAliasesBeforeRead(
                [roots.stateFile] + knownClients(roots: roots).map(\.configPath), lock: lock)
        }
        let snapshot = try RecoveryStore.load(roots: roots, strict: true)
        if let lock {
            try rejectLockAliasesBeforeRead(
                snapshot.ledger.entries.values.flatMap { [$0.configPath, $0.backupPath] },
                lock: lock)
        }
        let owned = try authenticate(snapshot)
        let clients = try selectedClients(request.clients)
        var plans: [UsePlan] = []
        let nextSequence = (snapshot.ledger.entries.values.map(\.sequence).max() ?? -1) + 1
        var sequence = nextSequence
        let planTimestamp = timestamp()

        for client in clients {
            let scope = Scope.normalized(for: client.name, requested: request.scope)
            let chain = owned[client.configPath.standardizedFileURL.path]
            let configRoute =
                try chain?.config.route ?? FileRoute.capture(logical: client.configPath)
            let configBytes = try chain?.config.bytes ?? authenticatedBytes(configRoute)
            let current = try ConfigCodec.readServer(
                client: client,
                bytes: configBytes,
                server: source.server,
                repo: source.repo,
                scope: scope
            )
            var environment = current?.environment ?? [:]
            if request.environment["LIBTMUX_TOOLSETS"] != nil {
                environment.removeValue(forKey: "LIBTMUX_SAFETY")
            }
            environment.merge(request.environment) {
                _, requested in requested
            }
            var spec = source.spec
            spec.environment = environment
            if let current, pointsAt(current, spec), current.environment == spec.environment {
                continue
            }
            let mutation = try ConfigCodec.settingServer(
                client: client,
                bytes: configBytes,
                server: source.server,
                spec: spec,
                repo: source.repo,
                scope: scope
            )
            let key = stateKey(client.name, scope)
            let prior = snapshot.ledger.entries[key]
            let backup: PlannedBackup
            var rewrites: [PlannedBackupRewrite] = []
            if prior != nil {
                guard let chain, let selectedIndex = chain.keys.firstIndex(of: key),
                    let existing = chain.backups[key]
                else {
                    throw SwapError.message(
                        "recovery stack is incomplete for \(client.configPath.path)")
                }
                backup = .existing(existing)
                for index in 0..<selectedIndex {
                    let newerKey = chain.keys[index]
                    let revealedKey = chain.keys[index + 1]
                    guard let value = chain.backups[newerKey],
                        let newerEntry = snapshot.ledger.entries[newerKey]
                    else { throw SwapError.message("recovery stack is incomplete") }
                    let rewritten = try ConfigCodec.settingServer(
                        client: client,
                        bytes: value.bytes,
                        server: source.server,
                        spec: spec,
                        repo: source.repo,
                        scope: scope
                    ).bytes
                    rewrites.append(
                        PlannedBackupRewrite(
                            ownerKey: newerKey,
                            revealedKey: revealedKey,
                            route: value.route,
                            originalBytes: value.bytes,
                            newBytes: rewritten,
                            revealedMode: newerEntry.originalMode
                        ))
                }
            } else {
                let path = nextBackupPath(
                    for: client.configPath, timestamp: planTimestamp,
                    scope: client.name == .claude ? scope : nil)
                backup = .new(try MissingRoute.capture(logical: path))
                sequence += 1
            }
            plans.append(
                UsePlan(
                    client: client,
                    scope: scope,
                    config: AuthenticatedFile(route: configRoute, bytes: configBytes),
                    newBytes: mutation.bytes,
                    action: mutation.action,
                    spec: spec,
                    server: source.server,
                    swappedAt: planTimestamp,
                    sequence: prior?.sequence ?? sequence - 1,
                    priorKey: prior == nil ? nil : key,
                    chainOwnerKey: chain?.keys.first,
                    backup: backup,
                    rewrites: rewrites
                ))
        }
        try rejectAliases(
            snapshot: snapshot, owned: owned, newPlans: plans, lock: lock)
        let report = OperationReport(
            changes: plans.map {
                OperationChange(
                    label: label($0.client.name, $0.scope),
                    path: $0.client.configPath,
                    action: $0.action.rawValue,
                    backup: $0.backup.path,
                    before: $0.config.bytes,
                    after: $0.newBytes)
            },
            messages: plans.isEmpty ? ["already points at the requested source"] : [],
            warnings: []
        )
        return UseTransaction(
            source: source, snapshot: snapshot, owned: owned, plans: plans, report: report)
    }

    private func commitUse(_ transaction: UseTransaction, lock: TransactionLock) throws
        -> OperationReport
    {
        try lock.verify()
        try transaction.snapshot.verify()
        try transaction.owned.values.forEach { try $0.verify() }

        var stagedOutputs: [String: StagedFile] = [:]
        var stagedBackups: [String: StagedFile] = [:]
        var stagedRewrites: [String: StagedFile] = [:]
        var publishedBackups: [FileRoute] = []
        var rewriteResults: [ReplacementResult] = []
        var configResults: [ReplacementResult] = []
        var stateResult: StateCommit?
        var allStages: [StagedFile] = []
        var nextEntries = transaction.snapshot.ledger.entries

        do {
            for plan in transaction.plans {
                let output = try StagedFile.create(
                    directory: plan.config.route.resolved.deletingLastPathComponent(),
                    label: "config-output",
                    bytes: plan.newBytes,
                    mode: plan.config.route.target.mode)
                stagedOutputs[plan.key] = output
                allStages.append(output)
                if case .new(let route) = plan.backup {
                    let backup = try StagedFile.create(
                        directory: route.resolved.deletingLastPathComponent(),
                        label: "backup",
                        bytes: plan.config.bytes,
                        mode: 0o600)
                    stagedBackups[plan.key] = backup
                    allStages.append(backup)
                }
                for rewrite in plan.rewrites {
                    let output = try StagedFile.create(
                        directory: rewrite.route.resolved.deletingLastPathComponent(),
                        label: "backup-output",
                        bytes: rewrite.newBytes,
                        mode: rewrite.route.target.mode)
                    stagedRewrites[rewrite.ownerKey] = output
                    allStages.append(output)
                }
            }

            for plan in transaction.plans {
                guard let output = stagedOutputs[plan.key] else {
                    throw SwapError.message("config output was not staged")
                }
                let expectedConfig = route(plan.config.route, replacingTarget: output.identity)
                for rewrite in plan.rewrites {
                    guard let output = stagedRewrites[rewrite.ownerKey],
                        let owner = nextEntries[rewrite.ownerKey],
                        let revealed = nextEntries[rewrite.revealedKey]
                    else { throw SwapError.message("backup rewrite was not staged") }
                    nextEntries[rewrite.ownerKey] = copyEntry(
                        owner,
                        expectedBackup: route(rewrite.route, replacingTarget: output.identity))
                    let identity = identity(output.identity, replacingMode: rewrite.revealedMode)
                    nextEntries[rewrite.revealedKey] = copyEntry(
                        revealed,
                        expectedConfig: route(plan.config.route, replacingTarget: identity))
                }
                if let priorKey = plan.priorKey {
                    guard let ownerKey = plan.chainOwnerKey, let owner = nextEntries[ownerKey]
                    else { throw SwapError.message("recovery owner is missing") }
                    nextEntries[ownerKey] = copyEntry(owner, expectedConfig: expectedConfig)
                    guard nextEntries[priorKey] != nil else {
                        throw SwapError.message("recovery entry disappeared")
                    }
                } else {
                    guard let backupStage = stagedBackups[plan.key] else {
                        throw SwapError.message("backup was not staged")
                    }
                    let expectedBackup: FileRoute
                    switch plan.backup {
                    case .new(let missing):
                        expectedBackup = route(missing, target: backupStage.identity)
                    case .existing:
                        throw SwapError.message("new recovery unexpectedly uses an existing backup")
                    }
                    nextEntries[plan.key] = RecoveryEntry(
                        client: plan.client.name,
                        scope: plan.scope,
                        configPath: plan.client.configPath.standardizedFileURL,
                        backupPath: plan.backup.path,
                        server: plan.server,
                        action: plan.action,
                        swappedAt: plan.swappedAt,
                        sequence: plan.sequence,
                        originalMode: plan.config.route.target.mode,
                        expectedConfig: expectedConfig,
                        expectedBackup: expectedBackup)
                }
            }

            let ledger = RecoveryLedger(entries: nextEntries)
            let stateStage = try StagedFile.create(
                directory: roots.stateDirectory,
                label: "state",
                bytes: try ledger.encoded(),
                mode: 0o600)
            allStages.append(stateStage)

            for plan in transaction.plans {
                guard case .new(let missing) = plan.backup,
                    let backup = stagedBackups[plan.key]
                else { continue }
                try commitHook(
                    .beforeBackupPublication(plan.client.name, plan.scope, missing.logical))
                publishedBackups.append(try publishAbsent(missing, from: backup))
            }
            for plan in transaction.plans {
                for rewrite in plan.rewrites {
                    guard let output = stagedRewrites[rewrite.ownerKey] else {
                        throw SwapError.message("backup rewrite output disappeared")
                    }
                    try commitHook(
                        .beforeBackupRewrite(plan.client.name, plan.scope, rewrite.route.logical))
                    rewriteResults.append(try replaceExact(rewrite.route, with: output))
                }
            }

            try lock.verify()
            try commitHook(.beforeState)
            if let stateRoute = transaction.snapshot.route {
                stateResult = .replaced(try replaceExact(stateRoute, with: stateStage))
            } else {
                stateResult = .published(
                    try publishAbsent(
                        try MissingRoute.capture(logical: roots.stateFile), from: stateStage))
            }

            for plan in transaction.plans {
                try lock.verify()
                try commitHook(.beforeConfig(plan.client.name))
                guard let output = stagedOutputs[plan.key] else {
                    throw SwapError.message("config output disappeared")
                }
                configResults.append(try replaceExact(plan.config.route, with: output))
            }

            let committed = try RecoveryStore.load(roots: roots, strict: true)
            _ = try authenticate(committed)
        } catch {
            let rollback = rollbackUse(
                configResults: configResults,
                stateResult: stateResult,
                rewriteResults: rewriteResults,
                publishedBackups: publishedBackups)
            cleanup(allStages)
            guard rollback.isEmpty else {
                throw SwapError.message(
                    "swap failed: \(error); rollback incomplete: \(rollback.joined(separator: "; "))"
                )
            }
            throw error
        }

        var report = transaction.report
        report.warnings += cleanupCommitted(
            configResults.map(\.recovery) + rewriteResults.map(\.recovery)
                + (stateResult.map(recoveryFiles) ?? []))
        cleanup(allStages)
        return report
    }

    private func planRevert(_ request: RevertRequest, lock: TransactionLock?) throws
        -> RevertTransaction
    {
        if let lock {
            try rejectLockAliasesBeforeRead(
                [roots.stateFile] + knownClients(roots: roots).map(\.configPath), lock: lock)
        }
        let snapshot = try RecoveryStore.load(roots: roots, strict: true)
        if let lock {
            try rejectLockAliasesBeforeRead(
                snapshot.ledger.entries.values.flatMap { [$0.configPath, $0.backupPath] },
                lock: lock)
        }
        let owned = try authenticate(snapshot)
        if request.clients.isEmpty, snapshot.ledger.entries.isEmpty {
            throw SwapError.message("no recorded swaps — nothing to revert")
        }
        let targetNames =
            request.clients.isEmpty
            ? ClientName.allCases.filter { name in
                snapshot.ledger.entries.values.contains { $0.client == name }
            } : request.clients
        var selected = Set<String>()
        for name in targetNames {
            let scopes: [Scope]
            if name == .claude, let requested = request.scope {
                scopes = [requested]
            } else if name == .claude {
                scopes = Scope.allCases
            } else {
                scopes = [.user]
            }
            for scope in scopes where snapshot.ledger.entries[stateKey(name, scope)] != nil {
                selected.insert(stateKey(name, scope))
            }
        }
        var plans: [RevertPlan] = []
        for chain in owned.values {
            let keys = chain.keys.filter(selected.contains)
            guard !keys.isEmpty else { continue }
            guard Array(chain.keys.prefix(keys.count)) == keys else {
                throw SwapError.message(
                    "selected recovery layers are not the top of \(chain.client.configPath.path)")
            }
            guard let oldestKey = keys.last,
                let oldest = snapshot.ledger.entries[oldestKey],
                let backup = chain.backups[oldestKey]
            else { throw SwapError.message("recovery stack is incomplete") }
            plans.append(
                RevertPlan(
                    client: chain.client,
                    config: chain.config,
                    keys: keys,
                    backups: keys.compactMap { chain.backups[$0] },
                    restoreBytes: backup.bytes,
                    restoreMode: oldest.originalMode))
        }
        try rejectAliases(snapshot: snapshot, owned: owned, newPlans: [], lock: lock)
        let changes = plans.flatMap { plan in
            plan.keys.map { key in
                OperationChange(
                    label: key,
                    path: plan.client.configPath,
                    action: "restored",
                    backup: snapshot.ledger.entries[key]?.backupPath,
                    before: plan.config.bytes,
                    after: plan.restoreBytes)
            }
        }
        return RevertTransaction(
            snapshot: snapshot,
            owned: owned,
            plans: plans,
            report: OperationReport(
                changes: changes,
                messages: changes.isEmpty ? ["no matching recorded swaps"] : [],
                warnings: []))
    }

    private func commitRevert(_ transaction: RevertTransaction, lock: TransactionLock) throws
        -> OperationReport
    {
        try lock.verify()
        try transaction.snapshot.verify()
        try transaction.owned.values.forEach { try $0.verify() }
        var stages: [StagedFile] = []
        var configStages: [String: StagedFile] = [:]
        var configResults: [ReplacementResult] = []
        var stateResult: StateCommit?
        var removedBackups: [(AuthenticatedFile, StagedFile)] = []
        var next = transaction.snapshot.ledger.entries

        do {
            for plan in transaction.plans {
                let stage = try StagedFile.create(
                    directory: plan.config.route.resolved.deletingLastPathComponent(),
                    label: "restore",
                    bytes: plan.restoreBytes,
                    mode: plan.restoreMode)
                stages.append(stage)
                configStages[plan.client.configPath.path] = stage
                for key in plan.keys { next.removeValue(forKey: key) }
                let remaining = next.values
                    .filter { $0.configPath == plan.client.configPath.standardizedFileURL }
                    .max { $0.sequence < $1.sequence }
                if let remaining,
                    let remainingKey = next.first(where: { $0.value.sequence == remaining.sequence }
                    )?.key
                {
                    next[remainingKey] = copyEntry(
                        remaining,
                        expectedConfig: route(plan.config.route, replacingTarget: stage.identity))
                }
            }
            let stateStage: StagedFile?
            if next.isEmpty {
                stateStage = nil
            } else {
                stateStage = try StagedFile.create(
                    directory: roots.stateDirectory,
                    label: "state",
                    bytes: try RecoveryLedger(entries: next).encoded(),
                    mode: 0o600)
                stages.append(stateStage!)
            }

            for plan in transaction.plans {
                try lock.verify()
                try commitHook(.beforeConfig(plan.client.name))
                guard let stage = configStages[plan.client.configPath.path] else {
                    throw SwapError.message("restore output disappeared")
                }
                configResults.append(try replaceExact(plan.config.route, with: stage))
            }

            try lock.verify()
            try commitHook(.beforeState)
            guard let priorState = transaction.snapshot.route else {
                throw SwapError.message("recorded swaps have no recovery ledger")
            }
            if let stateStage {
                stateResult = .replaced(try replaceExact(priorState, with: stateStage))
            } else {
                stateResult = .removed(try removeExact(priorState))
            }

            for plan in transaction.plans {
                for (key, backup) in zip(plan.keys, plan.backups) {
                    let entry = try required(
                        transaction.snapshot.ledger.entries[key], "entry \(key)")
                    try lock.verify()
                    try commitHook(
                        .beforeBackupRemoval(entry.client, entry.scope, backup.route.logical))
                    removedBackups.append((backup, try removeExact(backup.route)))
                }
            }

            if pathExists(roots.stateFile) {
                let committed = try RecoveryStore.load(roots: roots, strict: true)
                _ = try authenticate(committed)
            } else if !next.isEmpty {
                throw SwapError.message("recovery state disappeared after revert")
            }
        } catch {
            let rollback = rollbackRevert(
                removedBackups: removedBackups,
                stateResult: stateResult,
                configResults: configResults)
            cleanup(stages)
            guard rollback.isEmpty else {
                throw SwapError.message(
                    "revert failed: \(error); rollback incomplete: \(rollback.joined(separator: "; "))"
                )
            }
            throw error
        }

        var report = transaction.report
        report.warnings += cleanupCommitted(
            configResults.map(\.recovery) + removedBackups.map(\.1)
                + (stateResult.map(recoveryFiles) ?? []))
        cleanup(stages)
        return report
    }

    private func authenticate(_ snapshot: RecoverySnapshot) throws -> [String: OwnedChain] {
        var groups: [String: [String]] = [:]
        for (key, entry) in snapshot.ledger.entries {
            groups[entry.configPath.standardizedFileURL.path, default: []].append(key)
        }
        var result: [String: OwnedChain] = [:]
        let catalog = knownClients(roots: roots)
        for (path, unsortedKeys) in groups {
            let entries = try unsortedKeys.map {
                try required(snapshot.ledger.entries[$0], "entry \($0)")
            }
            guard Set(entries.map(\.client)).count == 1,
                let name = entries.first?.client,
                let client = catalog.first(where: { $0.name == name }),
                client.configPath.standardizedFileURL.path == path
            else { throw SwapError.message("multiple clients or paths claim recovery for \(path)") }
            let keys = unsortedKeys.sorted {
                snapshot.ledger.entries[$0]!.sequence > snapshot.ledger.entries[$1]!.sequence
            }
            let configRoute = try FileRoute.capture(logical: client.configPath)
            guard let top = snapshot.ledger.entries[keys[0]], configRoute == top.expectedConfig
            else {
                throw SwapError.message("config no longer matches recovery state: \(path)")
            }
            let configBytes = try authenticatedBytes(configRoute)
            try ConfigCodec.validate(client: client, bytes: configBytes)
            _ = try ConfigCodec.readServer(
                client: client,
                bytes: configBytes,
                server: top.server,
                repo: URL(fileURLWithPath: "/"),
                scope: top.scope)
            var backups: [String: AuthenticatedFile] = [:]
            for key in keys {
                guard let entry = snapshot.ledger.entries[key],
                    entry.expectedConfig.sameTopology(as: configRoute)
                else { throw SwapError.message("recovery route changed for \(path)") }
                let route = try FileRoute.capture(logical: entry.backupPath)
                guard route == entry.expectedBackup else {
                    throw SwapError.message(
                        "backup no longer matches recovery state: \(entry.backupPath.path)")
                }
                let bytes = try authenticatedBytes(route)
                try ConfigCodec.validate(client: client, bytes: bytes)
                backups[key] = AuthenticatedFile(route: route, bytes: bytes)
            }
            if keys.count > 1 {
                for index in 0..<(keys.count - 1) {
                    let newer = snapshot.ledger.entries[keys[index]]!
                    let older = snapshot.ledger.entries[keys[index + 1]]!
                    guard newer.expectedBackup.target.digest == older.expectedConfig.target.digest,
                        newer.expectedBackup.target.size == older.expectedConfig.target.size,
                        newer.originalMode == older.expectedConfig.target.mode
                    else {
                        throw SwapError.message("recovery layers are not a valid stack: \(path)")
                    }
                }
            }
            result[path] = OwnedChain(
                client: client,
                config: AuthenticatedFile(route: configRoute, bytes: configBytes),
                keys: keys,
                backups: backups)
        }
        return result
    }

    private func selectedClients(_ names: [ClientName]) throws -> [Client] {
        let catalog = knownClients(roots: roots)
        if names.isEmpty {
            let detected = catalog.filter {
                executableLookup($0.binary) != nil && pathExists($0.configPath)
            }
            guard !detected.isEmpty else {
                throw SwapError.message("no clients detected — nothing to do")
            }
            return detected
        }
        let wanted = Set(names)
        let selected = catalog.filter { wanted.contains($0.name) }
        for client in selected where !pathExists(client.configPath) {
            throw SwapError.message(
                "config not found for \(client.name.rawValue): \(client.configPath.path)")
        }
        return selected
    }

    private func rejectAliases(
        snapshot: RecoverySnapshot,
        owned: [String: OwnedChain],
        newPlans: [UsePlan],
        lock: TransactionLock?
    ) throws {
        var claims: [ArtifactClaim] = []
        if let route = snapshot.route {
            claims.append(claim("swap state", route))
        } else {
            claims.append(claim("swap state", roots.stateFile))
        }
        if let lock {
            claims.append(claim("swap lock", lock.route))
        } else if pathExists(roots.lockFile) {
            claims.append(try metadataClaim("swap lock", roots.lockFile))
        } else {
            claims.append(claim("swap lock", roots.lockFile))
        }
        for chain in owned.values {
            claims.append(claim("\(chain.client.name.rawValue) config", chain.config.route))
            for (key, backup) in chain.backups {
                claims.append(claim("\(key) backup", backup.route))
            }
        }
        let ownedPaths = Set(owned.keys)
        for plan in newPlans where !ownedPaths.contains(plan.client.configPath.path) {
            claims.append(claim("\(plan.client.name.rawValue) config", plan.config.route))
        }
        for plan in newPlans {
            if case .new(let missing) = plan.backup {
                claims.append(
                    ArtifactClaim(
                        label: "\(plan.key) backup",
                        logical: missing.logical.path,
                        resolved: missing.resolved.path,
                        physicalKey: nil,
                        links: nil))
            }
        }
        for left in claims.indices {
            if claims[left].links.map({ $0 != 1 }) == true {
                throw SwapError.message("\(claims[left].label) is hard-linked")
            }
            for right in claims.indices where right > left {
                let a = claims[left]
                let b = claims[right]
                let pathsA = Set([a.logical, a.resolved])
                let pathsB = Set([b.logical, b.resolved])
                if !pathsA.isDisjoint(with: pathsB)
                    || (a.physicalKey != nil && a.physicalKey == b.physicalKey)
                {
                    throw SwapError.message(
                        "duplicate transaction destination for \(a.label) and \(b.label)")
                }
            }
        }
    }

    private func rollbackUse(
        configResults: [ReplacementResult],
        stateResult: StateCommit?,
        rewriteResults: [ReplacementResult],
        publishedBackups: [FileRoute]
    ) -> [String] {
        var errors: [String] = []
        for result in configResults.reversed() {
            rollback(result, label: "config", errors: &errors)
        }
        if let stateResult { rollback(stateResult, label: "state", errors: &errors) }
        for result in rewriteResults.reversed() {
            rollback(result, label: "backup", errors: &errors)
        }
        for route in publishedBackups.reversed() {
            do { try removeExact(route).removeIfOwned() } catch {
                errors.append("backup: \(error)")
            }
        }
        return errors
    }

    private func rollbackRevert(
        removedBackups: [(AuthenticatedFile, StagedFile)],
        stateResult: StateCommit?,
        configResults: [ReplacementResult]
    ) -> [String] {
        var errors: [String] = []
        for (backup, removed) in removedBackups.reversed() {
            do {
                let missing = try MissingRoute.capture(logical: backup.route.logical)
                _ = try publishAbsent(missing, from: removed)
            } catch { errors.append("backup: \(error)") }
        }
        if let stateResult { rollback(stateResult, label: "state", errors: &errors) }
        for result in configResults.reversed() {
            rollback(result, label: "config", errors: &errors)
        }
        return errors
    }

    private func rollback(_ result: ReplacementResult, label: String, errors: inout [String]) {
        do {
            let restored = try replaceExact(result.current, with: result.recovery)
            try restored.recovery.removeIfOwned()
        } catch { errors.append("\(label): \(error)") }
    }

    private func rollback(_ result: StateCommit, label: String, errors: inout [String]) {
        switch result {
        case .replaced(let replacement): rollback(replacement, label: label, errors: &errors)
        case .published(let route):
            do { try removeExact(route).removeIfOwned() } catch {
                errors.append("\(label): \(error)")
            }
        case .removed(let staged):
            do {
                _ = try publishAbsent(
                    try MissingRoute.capture(logical: roots.stateFile), from: staged)
            } catch { errors.append("\(label): \(error)") }
        }
    }

    private func cleanupCommitted(_ files: [StagedFile]) -> [String] {
        var warnings: [String] = []
        for file in files {
            do { try file.removeIfOwned() } catch {
                warnings.append("cleanup retained \(file.path.path): \(error)")
            }
        }
        return warnings
    }

    private func cleanup(_ files: [StagedFile]) {
        for file in files { try? file.removeIfOwned() }
    }

    private static func currentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }
}

private struct ResolvedSource {
    let repo: URL
    let server: String
    let spec: ServerSpec
}

private struct AuthenticatedFile {
    let route: FileRoute
    let bytes: Data

    func verify() throws {
        try route.verify()
        guard try authenticatedBytes(route) == bytes else {
            throw SwapError.message("\(route.logical.path) bytes changed")
        }
    }
}

private struct OwnedChain {
    let client: Client
    let config: AuthenticatedFile
    let keys: [String]
    let backups: [String: AuthenticatedFile]

    func verify() throws {
        try config.verify()
        try backups.values.forEach { try $0.verify() }
    }
}

private enum PlannedBackup {
    case new(MissingRoute)
    case existing(AuthenticatedFile)

    var path: URL {
        switch self {
        case .new(let route): route.logical
        case .existing(let file): file.route.logical
        }
    }
}

private struct PlannedBackupRewrite {
    let ownerKey: String
    let revealedKey: String
    let route: FileRoute
    let originalBytes: Data
    let newBytes: Data
    let revealedMode: UInt32
}

private struct UsePlan {
    let client: Client
    let scope: Scope
    let config: AuthenticatedFile
    let newBytes: Data
    let action: ConfigAction
    let spec: ServerSpec
    let server: String
    let swappedAt: String
    let sequence: Int
    let priorKey: String?
    let chainOwnerKey: String?
    let backup: PlannedBackup
    let rewrites: [PlannedBackupRewrite]

    var key: String { stateKey(client.name, scope) }
}

private struct UseTransaction {
    let source: ResolvedSource
    let snapshot: RecoverySnapshot
    let owned: [String: OwnedChain]
    let plans: [UsePlan]
    let report: OperationReport

    var fingerprint: String {
        plans.map {
            "\($0.key):\($0.config.route.target.physicalKey):\(SHA256.hex($0.newBytes))"
        }.joined(separator: "|")
    }
}

private struct RevertPlan {
    let client: Client
    let config: AuthenticatedFile
    let keys: [String]
    let backups: [AuthenticatedFile]
    let restoreBytes: Data
    let restoreMode: UInt32
}

private struct RevertTransaction {
    let snapshot: RecoverySnapshot
    let owned: [String: OwnedChain]
    let plans: [RevertPlan]
    let report: OperationReport
}

private enum StateCommit {
    case replaced(ReplacementResult)
    case published(FileRoute)
    case removed(StagedFile)
}

private struct ArtifactClaim {
    let label: String
    let logical: String
    let resolved: String
    let physicalKey: String?
    let links: UInt64?
}

private func claim(_ label: String, _ route: FileRoute) -> ArtifactClaim {
    ArtifactClaim(
        label: label,
        logical: route.logical.path,
        resolved: route.resolved.path,
        physicalKey: route.target.physicalKey,
        links: route.target.links)
}

private func claim(_ label: String, _ url: URL) -> ArtifactClaim {
    let logical = url.standardizedFileURL
    return ArtifactClaim(
        label: label,
        logical: logical.path,
        resolved: logical.resolvingSymlinksInPath().path,
        physicalKey: nil,
        links: nil)
}

private func metadataClaim(_ label: String, _ url: URL) throws -> ArtifactClaim {
    let logical = url.standardizedFileURL
    let resolved = logical.resolvingSymlinksInPath().standardizedFileURL
    let identity = try FileIdentity.captureMetadata(resolved)
    return ArtifactClaim(
        label: label,
        logical: logical.path,
        resolved: resolved.path,
        physicalKey: identity.physicalKey,
        links: identity.links)
}

private func stateKey(_ client: ClientName, _ scope: Scope) -> String {
    "\(client.rawValue):\(scope.rawValue)"
}

private func label(_ client: ClientName, _ scope: Scope) -> String {
    client == .claude ? stateKey(client, scope) : client.rawValue
}

private func pointsAt(_ current: ServerSpec, _ target: ServerSpec) -> Bool {
    if let pullRequest = target.pullRequest {
        guard let currentPullRequest = current.pullRequest else { return false }
        return currentPullRequest.url == pullRequest.url
            && currentPullRequest.number == pullRequest.number
    }
    return current.command == target.command && current.arguments == target.arguments
}

private func pathExists(_ url: URL) -> Bool {
    (try? FileIdentity.captureMetadata(url, follow: false)) != nil
}

private func authenticatedBytes(_ route: FileRoute) throws -> Data {
    let data = try Data(contentsOf: route.resolved)
    guard SHA256.hex(data) == route.target.digest else {
        throw SwapError.message("\(route.logical.path) changed while it was read")
    }
    try route.verify()
    return data
}

private func nextBackupPath(for config: URL, timestamp: String, scope: Scope?) -> URL {
    let scopeSuffix = scope.map { "-\($0.rawValue)" } ?? ""
    let base = config.path + ".bak.mcp-swap-swift-" + timestamp + scopeSuffix
    var candidate = URL(fileURLWithPath: base)
    var counter = 2
    while pathExists(candidate) {
        candidate = URL(fileURLWithPath: "\(base)-\(counter)")
        counter += 1
    }
    return candidate
}

private func route(_ original: FileRoute, replacingTarget target: FileIdentity) -> FileRoute {
    FileRoute(
        logical: original.logical,
        resolved: original.resolved,
        logicalNodes: original.logicalNodes,
        resolvedParent: original.resolvedParent,
        target: target)
}

private func route(_ missing: MissingRoute, target: FileIdentity) -> FileRoute {
    FileRoute(
        logical: missing.logical,
        resolved: missing.resolved,
        logicalNodes: missing.logicalParentNodes,
        resolvedParent: missing.resolvedParent,
        target: target)
}

private func identity(_ original: FileIdentity, replacingMode mode: UInt32) -> FileIdentity {
    FileIdentity(
        device: original.device,
        inode: original.inode,
        mode: mode,
        size: original.size,
        modifiedSeconds: original.modifiedSeconds,
        modifiedNanoseconds: original.modifiedNanoseconds,
        links: original.links,
        kind: original.kind,
        digest: original.digest)
}

private func copyEntry(
    _ original: RecoveryEntry,
    expectedConfig: FileRoute? = nil,
    expectedBackup: FileRoute? = nil
) -> RecoveryEntry {
    RecoveryEntry(
        client: original.client,
        scope: original.scope,
        configPath: original.configPath,
        backupPath: original.backupPath,
        server: original.server,
        action: original.action,
        swappedAt: original.swappedAt,
        sequence: original.sequence,
        originalMode: original.originalMode,
        expectedConfig: expectedConfig ?? original.expectedConfig,
        expectedBackup: expectedBackup ?? original.expectedBackup)
}

private func recoveryFiles(_ state: StateCommit) -> [StagedFile] {
    switch state {
    case .replaced(let result): [result.recovery]
    case .published: []
    case .removed(let file): [file]
    }
}

private func required<T>(_ value: T?, _ label: String) throws -> T {
    guard let value else { throw SwapError.message("missing \(label)") }
    return value
}

func gitRemoteURL(repo: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", repo.path, "remote", "get-url", "origin"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do { try process.run() } catch {
        throw SwapError.message("could not inspect origin remote: \(error)")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SwapError.message("origin remote is not configured")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return try strictUTF8(data, label: "origin remote").trimmingCharacters(
        in: .whitespacesAndNewlines)
}
