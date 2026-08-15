import Foundation
import Testing

@testable import SpikeSupport

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite("tmux matrix manifest", .serialized)
struct TmuxMatrixTests {
    @Test(
        "source digests require exact lowercase SHA-256 evidence",
        arguments: [
            "sha256:abc",
            "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "sha256:" + String(repeating: "０", count: 64),
            "1111111111111111111111111111111111111111111111111111111111111111",
            validRefsSHA256 + "\n",
            validRefsSHA256 + "\r",
            validRefsSHA256 + "\t",
            validRefsSHA256 + "suffix",
        ]
    )
    func sourceDigestsRequireExactLowercaseSHA256Evidence(_ digest: String) throws {
        try withMatrixFixture(tags: requiredTags, sourceDigest: digest) { fixture in
            try expectMatrixError(.unauthenticatedSource, fixture: fixture)
        }
    }

    @Test(
        "matrix runner rejects malformed source digests",
        arguments: [
            "sha256:not-a-digest",
            validRefsSHA256 + "\n",
            validRefsSHA256 + "\r",
            validRefsSHA256 + "\t",
            validRefsSHA256 + "suffix",
        ]
    )
    func matrixRunnerRejectsMalformedSourceDigests(_ digest: String) throws {
        try withMatrixFixture(
            tags: requiredTags,
            sourceDigest: digest
        ) { fixture in
            let reply = try runProcess(
                "/bin/bash",
                [matrixRunnerURL.path, "--", "/usr/bin/true"],
                environment: [
                    "LIBTMUX_MATRIX_BINARY_ROOT": fixture.root.path,
                    "LIBTMUX_MATRIX_MANIFEST": fixture.evidence.path,
                ]
            )

            #expect(reply.status != 0)
            #expect(reply.standardError.contains("tmux matrix source evidence is invalid"))
        }
    }

    @Test("matrix runner executes only the selected authenticated lane")
    func matrixRunnerExecutesOnlySelectedAuthenticatedLane() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let selectedTag = try #require(requiredTags.last)
            let probe = try makeMatrixLaneProbe(
                named: "selected-lane-probe",
                body: #"""
                    record="$LIBTMUX_MATRIX_BINARY_ROOT/selected-$LIBTMUX_TMUX_TAG"
                    printf '%s\n' "$LIBTMUX_TMUX_TAG" >"$record"
                    """#,
                in: fixture.root
            )
            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: fixture.temporaryRoot,
                selectedTag: selectedTag
            )

            #expect(reply.status == 0)
            #expect(reply.standardOutput.contains("[3.7b] starting"))
            #expect(reply.standardOutput.contains("[3.7b] passed"))
            for tag in requiredTags.dropLast() {
                #expect(!reply.standardOutput.contains("[\(tag)] starting"))
            }
            for tag in requiredTags {
                let marker = fixture.root.appendingPathComponent("selected-\(tag)")
                #expect(
                    FileManager.default.fileExists(atPath: marker.path)
                        == (tag == selectedTag)
                )
            }
        }
    }

    @Test("matrix runner rejects an unknown selected lane before launch")
    func matrixRunnerRejectsUnknownSelectedLaneBeforeLaunch() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let probe = try makeMatrixLaneProbe(
                named: "unknown-selected-lane-probe",
                body: #"""
                    : >"$LIBTMUX_MATRIX_BINARY_ROOT/unknown-selected-lane-ran"
                    """#,
                in: fixture.root
            )
            let temporaryRoot = fixture.temporaryRoot
            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: temporaryRoot,
                selectedTag: "3.8"
            )

            #expect(reply.status == 2)
            #expect(reply.standardError.contains("requested tmux matrix lane is unavailable"))
            #expect(try matrixLaneRoots(in: temporaryRoot).isEmpty)
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("unknown-selected-lane-ran").path
                )
            )
        }
    }

    @Test("selected execution still authenticates every matrix binary")
    func selectedExecutionStillAuthenticatesEveryMatrixBinary() throws {
        try withMatrixFixture(
            tags: requiredTags,
            changedBinaryTag: requiredTags[0],
            executableBinaries: true
        ) { fixture in
            let selectedTag = try #require(requiredTags.last)
            let probe = try makeMatrixLaneProbe(
                named: "selected-authentication-probe",
                body: #"""
                    : >"$LIBTMUX_MATRIX_BINARY_ROOT/selected-authentication-ran"
                    """#,
                in: fixture.root
            )
            let temporaryRoot = fixture.temporaryRoot
            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: temporaryRoot,
                selectedTag: selectedTag
            )

            #expect(reply.status != 0)
            #expect(reply.standardError.contains("tmux 3.2a binary hash does not match"))
            #expect(try matrixLaneRoots(in: temporaryRoot).isEmpty)
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("selected-authentication-ran").path
                )
            )
        }
    }

    @Test("direct fixture gate provisions one short private lane")
    func directFixtureGateProvisionsOneShortPrivateLane() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let harness = try makeDirectGateHarness(in: fixture.root, mainStatus: 0)
            let selectedTag = try #require(requiredTags.last)
            let reply = try runDirectFixtureGate(fixture: fixture, harness: harness)
            let laneLog =
                (try? String(
                    contentsOf: fixture.root
                        .appendingPathComponent("runner-logs", isDirectory: true)
                        .appendingPathComponent("\(selectedTag).log"),
                    encoding: .utf8
                )) ?? ""
            try #require(
                reply.status == 0,
                Comment(rawValue: reply.standardError + laneLog)
            )
            let main = try readKeyValueRecord(harness.mainRecord)
            let registry = try readKeyValueRecord(harness.registryRecord)
            let laneRoot = URL(
                fileURLWithPath: try #require(main["root"]),
                isDirectory: true
            )
            let directRoot = laneRoot.deletingLastPathComponent()
            let registryRoot = try #require(registry["tmp"])

            #expect(main["tag"] == selectedTag)
            #expect(
                main["binary"]
                    == fixture.root.appendingPathComponent("\(selectedTag)/bin/tmux").path
            )
            #expect(main["manifest"] == fixture.evidence.path)
            #expect(main["binary_root"] == fixture.root.path)
            #expect(
                main["pty_probe"]
                    == harness.probeDirectory.appendingPathComponent(
                        "pty-client-probe"
                    ).path)
            #expect(
                main["fixture_owner_helper"]
                    == harness.probeDirectory.appendingPathComponent(
                        "fixture-owner-helper"
                    ).path)
            #expect(main["home"] == harness.homeSentinel)
            #expect(main["tmp"] == laneRoot.appendingPathComponent("tmp").path)
            #expect(main["root_mode"] == "700")
            #expect(main["parent_mode"] == "700")
            #expect(laneRoot.path.utf8.count + fixtureSocketPathSuffixByteCount <= 103)
            #expect(registryRoot.utf8.count + fixtureSocketPathSuffixByteCount <= 103)
            #expect(registry["mode"] == "700")
            #expect(registry["home"] == "<unset>")
            #expect(!FileManager.default.fileExists(atPath: laneRoot.path))
            #expect(!FileManager.default.fileExists(atPath: directRoot.path))
            #expect(reply.standardOutput.contains("[\(selectedTag)] starting"))
            for tag in requiredTags.dropLast() {
                #expect(!reply.standardOutput.contains("[\(tag)] starting"))
            }
        }
    }

    @Test(
        "direct fixture gate rejects a partial lane environment",
        arguments: directLaneEnvironmentCases
    )
    func directFixtureGateRejectsPartialLaneEnvironment(
        _ laneEnvironment: DirectLaneEnvironmentCase
    ) throws {
        try withDisposableDirectory { root in
            let shims = root.appendingPathComponent("partial-lane-shims", isDirectory: true)
            let marker = root.appendingPathComponent("swift-ran")
            try FileManager.default.createDirectory(
                at: shims,
                withIntermediateDirectories: false
            )
            let swift = shims.appendingPathComponent("swift")
            try #"""
            #!/bin/sh
            : >'\#(shellSingleQuoted(marker.path))'
            exit 97
            """#.write(to: swift, atomically: true, encoding: .utf8)
            try makeExecutable(swift)

            var environment = minimalScriptEnvironment(shims: shims)
            environment.merge(laneEnvironment.environment) { _, replacement in replacement }
            let reply = try runProcess(
                "/bin/bash",
                [testSpikesURL.path, "--filter", "FixtureBakeoffTests"],
                environment: environment,
                replacingEnvironment: true
            )

            #expect(reply.status == 2)
            #expect(
                reply.standardError.contains("incomplete authenticated tmux lane environment")
            )
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test("direct fixture gate preserves failed lane artifacts")
    func directFixtureGatePreservesFailedLaneArtifacts() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let harness = try makeDirectGateHarness(in: fixture.root, mainStatus: 23)
            let reply = try runDirectFixtureGate(fixture: fixture, harness: harness)
            let main = try readKeyValueRecord(harness.mainRecord)
            let laneRoot = URL(
                fileURLWithPath: try #require(main["root"]),
                isDirectory: true
            )
            let directRoot = laneRoot.deletingLastPathComponent()
            defer {
                if directRoot.lastPathComponent.hasPrefix("l.") {
                    try? FileManager.default.removeItem(at: directRoot)
                }
            }

            #expect(reply.status != 0)
            #expect(FileManager.default.fileExists(atPath: laneRoot.path))
            #expect(FileManager.default.fileExists(atPath: directRoot.path))
            #expect(
                FileManager.default.fileExists(
                    atPath: laneRoot.appendingPathComponent("direct-marker").path
                )
            )
            #expect(!FileManager.default.fileExists(atPath: harness.registryRecord.path))
            #expect(reply.standardError.contains("failed with status 23"))
            #expect(reply.standardError.contains("matrix artifacts preserved at"))
        }
    }

    @Test(
        "full matrix provisions one short private parent",
        arguments: [Int32(0), Int32(23)]
    )
    func matrixRunnerProvisionsOneShortPrivateParent(
        _ firstLaneStatus: Int32
    ) throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let hostileTemporaryRoot = fixture.root.appendingPathComponent(
                String(repeating: "ambient-temporary-root-is-too-long-", count: 4),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: hostileTemporaryRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let probe = try makeMatrixLaneProbe(
                named: "short-matrix-parent-probe-\(firstLaneStatus)",
                body: #"""
                    mode_of() {
                        stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
                    }
                    record="$LIBTMUX_MATRIX_BINARY_ROOT/parent-$LIBTMUX_TMUX_TAG"
                    root=$LIBTMUX_MATRIX_ROOT
                    parent=${root%/*}
                    {
                        printf 'tag=%s\n' "$LIBTMUX_TMUX_TAG"
                        printf 'root=%s\n' "$root"
                        printf 'parent=%s\n' "$parent"
                        printf 'parent_mode=%s\n' "$(mode_of "$parent")"
                    } >"$record.pending"
                    mv "$record.pending" "$record"
                    if [[ $LIBTMUX_TMUX_TAG == 3.2a ]]; then
                        exit \#(firstLaneStatus)
                    fi
                    """#,
                in: fixture.root
            )

            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: hostileTemporaryRoot
            )

            #expect(reply.status == (firstLaneStatus == 0 ? 0 : 1))
            let records = try requiredTags.map { tag in
                try readKeyValueRecord(
                    fixture.root.appendingPathComponent("parent-\(tag)")
                )
            }
            #expect(records.compactMap { $0["tag"] } == requiredTags)
            let parentPaths = Set(records.compactMap { $0["parent"] })
            #expect(parentPaths.count == 1)
            let parentPath = try #require(parentPaths.first)
            let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
            #expect(parent.lastPathComponent.hasPrefix("l."))
            #expect(!parent.path.hasPrefix(hostileTemporaryRoot.path + "/"))
            #expect(records.allSatisfy { $0["parent_mode"] == "700" })
            for record in records {
                let rootPath = try #require(record["root"])
                #expect(rootPath.utf8.count + fixtureSocketPathSuffixByteCount <= 103)
            }

            if firstLaneStatus == 0 {
                #expect(
                    records.allSatisfy { record in
                        guard let root = record["root"] else { return false }
                        return !FileManager.default.fileExists(atPath: root)
                    })
                #expect(!FileManager.default.fileExists(atPath: parent.path))
            } else {
                let firstRoot = try #require(records.first?["root"])
                #expect(FileManager.default.fileExists(atPath: firstRoot))
                #expect(
                    records.dropFirst().allSatisfy { record in
                        guard let root = record["root"] else { return false }
                        return !FileManager.default.fileExists(atPath: root)
                    })
                #expect(FileManager.default.fileExists(atPath: parent.path))
                #expect(reply.standardError.contains("matrix artifacts preserved at"))

                let canonicalSystemTemporaryDirectory = URL(
                    fileURLWithPath: "/tmp",
                    isDirectory: true
                ).resolvingSymlinksInPath().standardizedFileURL.path
                guard
                    parent.deletingLastPathComponent().standardizedFileURL.path
                        == canonicalSystemTemporaryDirectory,
                    parent.lastPathComponent.hasPrefix("l.")
                else {
                    Issue.record("refused to remove an unauthenticated matrix parent")
                    return
                }
                try FileManager.default.removeItem(at: parent)
            }
        }
    }

    @Test("matrix runner fails closed when an unused parent cannot be removed")
    func matrixRunnerFailsClosedWhenUnusedParentCannotBeRemoved() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let shims = fixture.root.appendingPathComponent(
                "matrix-parent-cleanup-shims",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: shims,
                withIntermediateDirectories: false
            )
            let chmodRecord = fixture.root.appendingPathComponent("failed-parent-chmod")
            let rmdirRecord = fixture.root.appendingPathComponent("failed-parent-rmdir")
            let quotedTemporaryRoot = shellSingleQuoted(fixture.temporaryRoot.path)

            let chmod = shims.appendingPathComponent("chmod")
            try #"""
            #!/bin/bash
            set -euo pipefail
            if [[ ${2:-} == '\#(quotedTemporaryRoot)'/l.* ]]; then
                printf '%s\n' "$2" >'\#(shellSingleQuoted(chmodRecord.path))'
                exit 1
            fi
            exec /bin/chmod "$@"
            """#.write(to: chmod, atomically: true, encoding: .utf8)
            try makeExecutable(chmod)

            let rmdir = shims.appendingPathComponent("rmdir")
            try #"""
            #!/bin/bash
            set -euo pipefail
            if [[ ${2:-} == '\#(quotedTemporaryRoot)'/l.* ]]; then
                printf '%s\n' "$2" >'\#(shellSingleQuoted(rmdirRecord.path))'
                exit 1
            fi
            exec /bin/rmdir "$@"
            """#.write(to: rmdir, atomically: true, encoding: .utf8)
            try makeExecutable(rmdir)

            let marker = fixture.root.appendingPathComponent("unexpected-parent-cleanup-lane")
            let probe = try makeMatrixLaneProbe(
                named: "parent-cleanup-probe",
                body: ": >'\(shellSingleQuoted(marker.path))'",
                in: fixture.root
            )
            let path =
                shims.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")

            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: fixture.temporaryRoot,
                environment: ["PATH": path]
            )

            #expect(reply.status != 0)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            let chmodPath = try String(contentsOf: chmodRecord, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rmdirPath = try String(contentsOf: rmdirRecord, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(chmodPath == rmdirPath)
            #expect(chmodPath.hasPrefix(fixture.temporaryRoot.path + "/l."))
            #expect(FileManager.default.fileExists(atPath: chmodPath))
            #expect(
                reply.standardError.contains(
                    "matrix parent validation failed; artifacts preserved at \(chmodPath)"
                )
            )
        }
    }

    @Test("matrix runner does not wait for deadlines after commands exit")
    func matrixRunnerDoesNotWaitForDeadlinesAfterCommandsExit() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let path = try pathShadowingSetsid(in: fixture.root)
            let clock = ContinuousClock()
            let start = clock.now
            let reply = try runMatrixRunner(
                fixture: fixture,
                command: URL(fileURLWithPath: "/usr/bin/true"),
                temporaryRoot: fixture.temporaryRoot,
                environment: [
                    "LIBTMUX_MATRIX_TIMEOUT_SECONDS": "30",
                    "PATH": path,
                ]
            )
            let elapsed = start.duration(to: clock.now)

            #expect(reply.status == 0)
            #expect(elapsed < .seconds(10))
            #expect(!FileManager.default.fileExists(atPath: setsidMarker(in: fixture.root).path))
        }
    }

    @Test("matrix runner preserves trace-shaped standard error")
    func matrixRunnerPreservesTraceShapedStandardError() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let probe = try makeMatrixLaneProbe(
                named: "trace-shaped-stderr-probe",
                body: #"""
                    if [[ -n ${BASH_XTRACEFD:-} ]] || ( : >&3 ) 2>/dev/null; then
                        exit 97
                    fi
                    printf '+TRACE: failure\n' >&2
                    """#,
                in: fixture.root
            )
            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: fixture.temporaryRoot,
                environment: [
                    "PATH": try pathEmittingTraceShapedMatrixStandardError(in: fixture.root)
                ]
            )

            #expect(reply.status == 0)
            #expect(
                reply.standardError
                    == String(repeating: "+TRACE: failure\n", count: requiredTags.count)
            )
            for tag in requiredTags {
                #expect(reply.standardOutput.contains("[\(tag)] +TRACE: failure"))
            }
        }
    }

    @Test(
        "matrix runner reaps descendants before applying its root policy",
        arguments: [Int32(0), Int32(23)]
    )
    func matrixRunnerReapsDescendantsBeforeApplyingRootPolicy(_ payloadStatus: Int32) throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let temporaryRoot = fixture.temporaryRoot
            let probe = try makeMatrixLaneProbe(
                named: "completed-lane-probe-\(payloadStatus)",
                body: #"""
                    bash -c 'trap "" HUP TERM; while :; do /bin/sleep 1; done' &
                    descendant=$!
                    supervisor=$(ps -o pgid= -p "$$" | tr -d ' ')
                    record="$LIBTMUX_MATRIX_BINARY_ROOT/process-$LIBTMUX_TMUX_TAG"
                    printf '%s %s %s\n' "$$" "$descendant" "$supervisor" >"$record.pending"
                    mv "$record.pending" "$record"
                    exit \#(payloadStatus)
                    """#,
                in: fixture.root
            )

            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: temporaryRoot
            )

            #expect(reply.status == (payloadStatus == 0 ? 0 : 1))
            if payloadStatus == 0 {
                #expect(try matrixLaneRoots(in: temporaryRoot).isEmpty)
                for tag in requiredTags {
                    #expect(reply.standardOutput.contains("[\(tag)] passed"))
                }
            } else {
                #expect(
                    reply.standardError.components(
                        separatedBy: "failed with status \(payloadStatus)"
                    ).count - 1 == requiredTags.count
                )
                try expectPreservedMatrixLaneRoots(in: temporaryRoot)
            }

            var processIdentifiers: [Int32] = []
            for tag in requiredTags {
                let record = fixture.root.appendingPathComponent("process-\(tag)")
                let fields = try String(contentsOf: record, encoding: .utf8)
                    .split(whereSeparator: \Character.isWhitespace)
                #expect(fields.count == 3)
                let payload = try #require(Int32(fields[0]))
                let descendant = try #require(Int32(fields[1]))
                let supervisorPGID = try #require(Int32(fields[2]))
                #expect(Set([payload, descendant, supervisorPGID]).count == 3)
                #expect(payload != supervisorPGID)
                processIdentifiers.append(contentsOf: [payload, descendant, supervisorPGID])
            }
            waitForProcessesToExit(processIdentifiers)
            for processIdentifier in processIdentifiers {
                #expect(!testProcessIsRunning(processIdentifier))
            }
        }
    }

    @Test(
        "matrix runner cleans up both ownership edges after post-spawn failures",
        arguments: MatrixPostSpawnFailureEdge.allCases
    )
    func matrixRunnerCleansUpAfterPostSpawnFailure(
        _ edge: MatrixPostSpawnFailureEdge
    ) throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let temporaryRoot = fixture.temporaryRoot
            let checkpoint = fixture.root.appendingPathComponent(
                "post-spawn-failure-\(edge.rawValue)"
            )
            let probe = try makeMatrixLaneProbe(
                named: "post-spawn-failure-probe-\(edge.rawValue)",
                body: #"""
                    if [[ "$LIBTMUX_TMUX_TAG" != "3.2a" ]]; then
                        exit 0
                    fi
                    trap '' HUP INT TERM
                    bash -c 'trap "" HUP INT TERM; while :; do /bin/sleep 1; done' &
                    descendant=$!
                    supervisor=$(ps -o pgid= -p "$$" | tr -d ' ')
                    record="$LIBTMUX_MATRIX_FAILURE_CHECKPOINT"
                    printf '%s %s %s\n' "$$" "$descendant" "$supervisor" >"$record.pending"
                    mv "$record.pending" "$record"
                    while :; do /bin/sleep 1; done
                    """#,
                in: fixture.root
            )

            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: temporaryRoot,
                environment: [
                    "LIBTMUX_MATRIX_FAILURE_CHECKPOINT": checkpoint.path,
                    "LIBTMUX_MATRIX_FAILURE_TAG": requiredTags[0],
                    "LIBTMUX_MATRIX_INJECT_POST_SPAWN_FAILURE": edge.rawValue,
                    "LIBTMUX_MATRIX_RELAY_PROBE": "1",
                    "LIBTMUX_MATRIX_TIMEOUT_SECONDS": "30",
                ]
            )

            #expect(reply.status == edge.expectedStatus)
            if edge == .laneToBounded {
                #expect(reply.standardError.contains("[3.2a] failed with status 91"))
            }
            try expectPreservedSignaledMatrixLaneRoot(
                in: temporaryRoot,
                payloadStarted: true
            )

            let processIdentifiers = try waitForMatrixSignalMarker(
                checkpoint,
                expectedCount: 3
            )
            let laneRoot = try #require(matrixLaneRoots(in: temporaryRoot).first)
            let relayIdentifiers = try waitForMatrixSignalMarker(
                laneRoot.appendingPathComponent("relay-ownership"),
                expectedCount: 3
            )
            let nestedProcessIdentifiers = Array(
                Set(processIdentifiers + Array(relayIdentifiers.dropFirst()))
            )

            #expect(nestedProcessIdentifiers.allSatisfy { $0 > 0 })
            waitForProcessesToExit(nestedProcessIdentifiers)
            for processIdentifier in nestedProcessIdentifiers {
                #expect(!testProcessIsRunning(processIdentifier))
            }
        }
    }

    @Test(
        "matrix runner retires prompt direct children without stale KILL",
        arguments: MatrixPostSpawnFailureEdge.allCases
    )
    func matrixRunnerRetiresPromptDirectChildrenWithoutStaleKill(
        _ edge: MatrixPostSpawnFailureEdge
    ) throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let temporaryRoot = fixture.temporaryRoot
            let checkpoint = fixture.root.appendingPathComponent(
                "prompt-retirement-\(edge.rawValue)"
            )
            let killProbe = try makeMatrixKillProbe(in: fixture.root)
            let reply = try runMatrixRunner(
                fixture: fixture,
                command: URL(fileURLWithPath: "/usr/bin/true"),
                temporaryRoot: temporaryRoot,
                environment: [
                    "LIBTMUX_MATRIX_FAILURE_CHECKPOINT": checkpoint.path,
                    "LIBTMUX_MATRIX_FAILURE_TAG": requiredTags[0],
                    "LIBTMUX_MATRIX_INJECT_AUTHENTICATION_FAILURE": edge.rawValue,
                    "LIBTMUX_MATRIX_INJECT_PROMPT_TERM_EXIT": edge.rawValue,
                    "LIBTMUX_MATRIX_INJECT_POST_SPAWN_FAILURE": edge.rawValue,
                    "LIBTMUX_MATRIX_KILL_TRACE_DIRECTORY": killProbe.records.path,
                    "LIBTMUX_MATRIX_RELAY_PROBE": "1",
                    "LIBTMUX_MATRIX_TIMEOUT_SECONDS": "30",
                    "PATH": killProbe.path,
                ]
            )

            #expect(reply.status == edge.expectedStatus)
            let parent: Int32
            let child: Int32
            var processIdentifiers: [Int32]
            switch edge {
            case .topToLane:
                let assignment = try #require(
                    matrixProcessAssignment(reply.trace, variable: "lane_child")
                )
                parent = assignment.owner
                child = assignment.processIdentifier
                processIdentifiers = [child]
                #expect(try matrixLaneRoots(in: temporaryRoot).isEmpty)
            case .laneToBounded:
                let laneRoot = try #require(matrixLaneRoots(in: temporaryRoot).first)
                let relayIdentifiers = try waitForMatrixSignalMarker(
                    laneRoot.appendingPathComponent("relay-ownership"),
                    expectedCount: 3
                )
                parent = relayIdentifiers[1]
                child = relayIdentifiers[2]
                processIdentifiers = relayIdentifiers
                try expectPreservedSignaledMatrixLaneRoot(
                    in: temporaryRoot,
                    payloadStarted: false
                )
            }
            let cleanupSignals = matrixOwnedJobSignals(
                reply.trace,
                parent: parent,
                edge: edge,
                child: child
            )

            #expect(cleanupSignals.map(\.signal).contains("TERM"))
            #expect(Set(cleanupSignals.map(\.jobSpec)).count == 1)
            #expect(
                try readMatrixKillRecords(from: killProbe.records).allSatisfy {
                    !($0.signal == "KILL" && $0.target == child)
                }
            )
            #expect(
                matrixOwnedJobSignalEvidenceIsAuthenticated(
                    reply.trace,
                    parent: parent,
                    edge: edge,
                    expectedSignal: "TERM",
                    expectedTarget: child
                )
            )
            #expect(
                matrixTraceEntries(reply.trace).contains {
                    $0.owner == parent
                        && $0.command
                            == "\(edge.reapedStatusVariable)=143"
                }
            )
            expectMatrixWaitAuthority(reply.trace, child: child)

            processIdentifiers = Array(Set(processIdentifiers))
            waitForProcessesToExit(processIdentifiers)
            for processIdentifier in processIdentifiers {
                #expect(!testProcessIsRunning(processIdentifier))
            }
        }
    }

    @Test(
        "matrix runner escalates owned stubborn direct children without stale PIDs",
        arguments: MatrixPostSpawnFailureEdge.allCases
    )
    func matrixRunnerEscalatesOwnedStubbornDirectChildrenWithoutStalePIDs(
        _ edge: MatrixPostSpawnFailureEdge
    ) throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let temporaryRoot = fixture.temporaryRoot
            let checkpoint = fixture.root.appendingPathComponent(
                "authentication-failure-\(edge.rawValue)"
            )
            let recoveryToken = "libtmux-matrix-owner-\(UUID().uuidString)"
            let killProbe = try makeMatrixKillProbe(in: fixture.root)
            let xtrace = fixture.root.appendingPathComponent(
                "authentication-xtrace-\(edge.rawValue)"
            )
            let running = try launchMatrixRunner(
                fixture: fixture,
                command: URL(fileURLWithPath: "/usr/bin/true"),
                temporaryRoot: temporaryRoot,
                environment: [
                    "LIBTMUX_MATRIX_FAILURE_CHECKPOINT": checkpoint.path,
                    "LIBTMUX_MATRIX_FAILURE_TAG": requiredTags[0],
                    "LIBTMUX_MATRIX_INJECT_AUTHENTICATION_FAILURE": edge.rawValue,
                    "LIBTMUX_MATRIX_INJECT_POST_SPAWN_FAILURE": edge.rawValue,
                    "LIBTMUX_MATRIX_KILL_TRACE_DIRECTORY": killProbe.records.path,
                    "LIBTMUX_MATRIX_RECOVERY_TOKEN": recoveryToken,
                    "LIBTMUX_MATRIX_RELAY_PROBE": "1",
                    "LIBTMUX_MATRIX_TIMEOUT_SECONDS": "30",
                    "PATH": killProbe.path,
                ],
                commandArguments: [recoveryToken],
                xtrace: xtrace
            )
            let topPID = running.owner.processIdentifier
            var runnerFinished = false
            defer {
                if !runnerFinished {
                    terminateMatrixRunner(running, recoveryToken: recoveryToken)
                }
            }

            try waitForMatrixRunnerExit(running)
            let reply = try finishMatrixRunner(running)
            #expect(reply.status == edge.expectedStatus)

            let parent: Int32
            let child: Int32
            switch edge {
            case .topToLane:
                parent = topPID
                child = try #require(
                    matrixAssignedProcessIdentifier(
                        reply.trace,
                        owner: topPID,
                        variable: "lane_child"
                    )
                )
                #expect(try matrixLaneRoots(in: temporaryRoot).isEmpty)
            case .laneToBounded:
                let laneRoot = try #require(matrixLaneRoots(in: temporaryRoot).first)
                let relayIdentifiers = try waitForMatrixSignalMarker(
                    laneRoot.appendingPathComponent("relay-ownership"),
                    expectedCount: 3
                )
                parent = relayIdentifiers[1]
                child = relayIdentifiers[2]
                try expectPreservedSignaledMatrixLaneRoot(
                    in: temporaryRoot,
                    payloadStarted: false
                )
            }

            let killRecords = try readMatrixKillRecords(from: killProbe.records)
            #expect(killRecords.allSatisfy { $0.target != child })
            let cleanupSignals = matrixOwnedJobSignals(
                reply.trace,
                parent: parent,
                edge: edge,
                child: child
            )
            #expect(cleanupSignals.map(\.signal).contains("TERM"))
            #expect(cleanupSignals.map(\.signal).contains("KILL"))
            #expect(Set(cleanupSignals.map(\.jobSpec)).count == 1)
            #expect(
                matrixOwnedJobSignalEvidenceIsAuthenticated(
                    reply.trace,
                    parent: parent,
                    edge: edge,
                    expectedSignal: "KILL",
                    expectedTarget: child
                )
            )
            #expect(
                matrixTraceEntries(reply.trace).contains {
                    $0.owner == parent
                        && $0.command
                            == "\(edge.reapedStatusVariable)=137"
                }
            )
            expectMatrixWaitAuthority(reply.trace, child: child)
            waitForProcessesToExit([child])
            #expect(!testProcessIsRunning(child))
            runnerFinished = true
        }
    }

    @Test(
        "matrix runner retires an uncaptured child without touching a current decoy",
        arguments: MatrixPostSpawnFailureEdge.allCases
    )
    func matrixRunnerRetiresUncapturedChildWithoutTouchingCurrentDecoy(
        _ edge: MatrixPostSpawnFailureEdge
    ) throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let marker = fixture.root.appendingPathComponent(
                "capture-failure-\(edge.rawValue)"
            )
            let decoyToken = "libtmux-matrix-decoy-\(UUID().uuidString)"
            let bashEnvironment = try makeMatrixCaptureFailureBashEnvironment(
                in: fixture.root
            )
            let probe = try makeMatrixLaneProbe(
                named: "capture-failure-probe-\(edge.rawValue)",
                body: "/bin/sleep 0.5",
                in: fixture.root
            )
            var capturedIdentifiers: [Int32] = []
            defer {
                retireMatrixCaptureFailureProcesses(
                    capturedIdentifiers,
                    decoyToken: decoyToken
                )
            }

            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: fixture.temporaryRoot,
                environment: [
                    "BASH_ENV": bashEnvironment.path,
                    "LIBTMUX_TEST_CAPTURE_ASSIGNMENT": edge.captureAssignment,
                    "LIBTMUX_TEST_CAPTURE_MARKER": marker.path,
                    "LIBTMUX_TEST_CAPTURE_TAG": requiredTags[0],
                    "LIBTMUX_TEST_DECOY_TOKEN": decoyToken,
                ]
            )
            capturedIdentifiers = try waitForMatrixSignalMarker(marker, expectedCount: 2)
            let original = capturedIdentifiers[0]
            let decoy = capturedIdentifiers[1]

            #expect(reply.status == edge.captureFailureStatus)
            #expect(!testProcessIsRunning(original))
            #expect(testProcessIsRunning(decoy))
            #expect(getpgid(decoy) == decoy)
            #expect(matrixProcessHasExactArgument(decoy, decoyToken))
            let originalWait = "wait \(original)"
            #expect(matrixTraceCommands(reply.trace).filter { $0 == originalWait }.count == 1)
            #expect(
                matrixTraceCommands(reply.trace).contains {
                    $0.hasPrefix("builtin kill -s KILL -- %")
                }
            )
        }
    }

    @Test("matrix runner preserves lane roots after timeout")
    func matrixRunnerLaneRootsArePreservedAfterTimeout() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let temporaryRoot = fixture.temporaryRoot
            let probe = try makeMatrixLaneProbe(
                named: "timed-out-lane-probe",
                body: "exec /bin/sleep 30",
                in: fixture.root
            )

            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: temporaryRoot,
                environment: [
                    "LIBTMUX_MATRIX_TIMEOUT_SECONDS": "1",
                    "PATH": try pathAcceleratingMatrixTimeout(in: fixture.root),
                ]
            )

            #expect(reply.status == 1)
            #expect(
                reply.standardError.components(separatedBy: "failed with status 124").count - 1 == 8
            )
            try expectPreservedMatrixLaneRoots(
                in: temporaryRoot,
                additionalArtifacts: ["timed-out"]
            )
        }
    }

    @Test("matrix runner preserves lane roots after a child signal")
    func matrixRunnerLaneRootsArePreservedAfterSignal() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let temporaryRoot = fixture.temporaryRoot
            let probe = try makeMatrixLaneProbe(
                named: "signaled-lane-probe",
                body: "kill -KILL \"$$\"",
                in: fixture.root
            )

            let reply = try runMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: temporaryRoot
            )

            #expect(reply.status == 1)
            #expect(
                reply.standardError.components(separatedBy: "failed with status 137").count - 1
                    == 8
            )
            try expectPreservedMatrixLaneRoots(in: temporaryRoot)
        }
    }

    @Test("matrix launch authentication failure reaps its direct child")
    func matrixLaunchAuthenticationFailureReapsItsDirectChild() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let temporaryRoot = fixture.temporaryRoot
            let recoveryToken = "libtmux-matrix-owner-\(UUID().uuidString)"
            let launchMarker = "libtmux-matrix-unauthenticated-\(UUID().uuidString)"
            let xtrace = fixture.root.appendingPathComponent("authentication-rollback-xtrace")
            let probe = try makeMatrixLaneProbe(
                named: "authentication-rollback-probe",
                body: "while :; do /bin/sleep 1; done",
                in: fixture.root
            )
            var failedLaunchProcessIdentifier: Int32?
            defer {
                if let failedLaunchProcessIdentifier {
                    stopAndReapFailedMatrixLaunchForTest(failedLaunchProcessIdentifier)
                }
            }

            do {
                _ = try launchMatrixRunner(
                    fixture: fixture,
                    command: probe,
                    temporaryRoot: temporaryRoot,
                    environment: [
                        "LIBTMUX_MATRIX_RECOVERY_TOKEN": recoveryToken,
                        "LIBTMUX_MATRIX_TIMEOUT_SECONDS": "30",
                    ],
                    commandArguments: [launchMarker],
                    xtrace: xtrace
                )
                Issue.record("matrix launch unexpectedly authenticated")
            } catch let MatrixRunnerHarnessError.launchAuthenticationFailed(
                processIdentifier,
                _,
                recoveryTokenPresent
            ) {
                failedLaunchProcessIdentifier = processIdentifier
                #expect(!recoveryTokenPresent)
                #expect(!testProcessIsRunning(processIdentifier))
                stopAndReapFailedMatrixLaunchForTest(processIdentifier)
                failedLaunchProcessIdentifier = nil
                waitForProcessesToExit(matrixProcessIdentifiers(withExactArgument: launchMarker))
                #expect(matrixProcessIdentifiers(withExactArgument: launchMarker).isEmpty)
            } catch {
                Issue.record("matrix launch threw an unexpected error: \(error)")
            }
        }
    }

    @Test("matrix runner requires exact job resolution before signaling")
    func matrixRunnerRequiresExactJobResolutionBeforeSignaling() {
        let parent: Int32 = 101
        let child: Int32 = 202
        let traceWithoutResolution = """
            +TRACE:101:relay_matrix_signal: signal_owned_job_handle top-to-lane HUP %2 202
            +TRACE:101:signal_owned_job_handle: builtin kill -s HUP -- %2
            +TRACE:101:main: wait 202
            """
        let traceWithResolution = """
            +TRACE:101:relay_matrix_signal: signal_owned_job_handle top-to-lane HUP %2 202
            +TRACE:101:owned_job_handle_is_active: jobs -x test %2 = 202
            +TRACE:101:owned_job_handle_is_active: test 202 = 202
            +TRACE:101:signal_owned_job_handle: builtin kill -s HUP -- %2
            +TRACE:101:main: wait 202
            """

        #expect(
            !matrixOwnedJobSignalEvidenceIsAuthenticated(
                traceWithoutResolution,
                parent: parent,
                edge: .topToLane,
                expectedSignal: "HUP",
                expectedTarget: child
            )
        )
        #expect(
            matrixOwnedJobSignalEvidenceIsAuthenticated(
                traceWithResolution,
                parent: parent,
                edge: .topToLane,
                expectedSignal: "HUP",
                expectedTarget: child
            )
        )
        #expect(
            !matrixOwnedJobSignalEvidenceIsAuthenticated(
                traceWithResolution.replacingOccurrences(of: "= 202", with: "= 303"),
                parent: parent,
                edge: .topToLane,
                expectedSignal: "HUP",
                expectedTarget: child
            )
        )
    }

    @Test(
        "matrix runner relays exact outer signals through each ownership phase",
        arguments: matrixSignalScenarios
    )
    func matrixRunnerRelaysExactOuterSignals(_ scenario: MatrixSignalScenario) throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let temporaryRoot = fixture.temporaryRoot
            let processMarker = fixture.root.appendingPathComponent(
                "signal-processes-\(scenario.phase.rawValue)-\(scenario.signal)"
            )
            let recoveryToken = "libtmux-matrix-owner-\(UUID().uuidString)"
            let killProbe = try makeMatrixKillProbe(in: fixture.root)
            let xtrace = fixture.root.appendingPathComponent(
                "matrix-xtrace-\(scenario.phase.rawValue)-\(scenario.signal)"
            )
            var environment = [
                "LIBTMUX_MATRIX_KILL_TRACE_DIRECTORY": killProbe.records.path,
                "LIBTMUX_MATRIX_RECOVERY_TOKEN": recoveryToken,
                "LIBTMUX_MATRIX_SIGNAL_MARKER": processMarker.path,
                "LIBTMUX_MATRIX_TIMEOUT_SECONDS": "30",
                "LIBTMUX_MATRIX_RELAY_PROBE": "1",
                "PATH": killProbe.path,
            ]
            let probeBody: String
            let checkpoint: URL

            switch scenario.phase {
            case .beforeRelease:
                let gate = fixture.root.appendingPathComponent(
                    "before-release-\(scenario.signal)"
                )
                try makeMatrixSignalFIFO(at: gate)
                environment["LIBTMUX_MATRIX_BEFORE_RELEASE_GATE"] = gate.path
                checkpoint = gate.appendingPathExtension("ready")
                probeBody = "exec /bin/sleep 30"
            case .payload:
                checkpoint = processMarker
                probeBody = matrixBlockingSignalProbeBody
            case .afterStatus:
                let gate = fixture.root.appendingPathComponent(
                    "after-status-\(scenario.signal)"
                )
                try makeMatrixSignalFIFO(at: gate)
                environment["LIBTMUX_MATRIX_AFTER_STATUS_GATE"] = gate.path
                checkpoint = gate.appendingPathExtension("ready")
                probeBody = matrixCompletedSignalProbeBody
            }

            let probe = try makeMatrixLaneProbe(
                named: "outer-signal-probe-\(scenario.phase.rawValue)-\(scenario.signal)",
                body: probeBody,
                in: fixture.root
            )
            let running = try launchMatrixRunner(
                fixture: fixture,
                command: probe,
                temporaryRoot: temporaryRoot,
                environment: environment,
                commandArguments: [recoveryToken],
                xtrace: xtrace
            )
            let topPID = running.owner.processIdentifier
            let topPGID = getpgid(topPID)
            var ownedProcessIdentifiers = [topPID]
            var runnerFinished = false
            defer {
                if !runnerFinished {
                    terminateMatrixRunner(running, recoveryToken: recoveryToken)
                }
            }

            #expect(topPID > 0)
            #expect(topPGID > 0)
            #expect(testProcessIsRunning(topPID))

            let checkpointFields = try waitForMatrixSignalMarker(
                checkpoint,
                expectedCount: scenario.phase == .payload ? 3 : 2
            )
            let laneRoot = try #require(matrixLaneRoots(in: temporaryRoot).first)
            let relayFields = try waitForMatrixSignalMarker(
                laneRoot.appendingPathComponent("relay-ownership"),
                expectedCount: 3
            )
            let lanePID = relayFields[1]
            let boundedRunnerPID = relayFields[2]
            #expect(relayFields[0] == topPID)
            #expect(Set(relayFields).count == 3)
            #expect(getpgid(lanePID) == lanePID)
            #expect(getpgid(boundedRunnerPID) == boundedRunnerPID)
            ownedProcessIdentifiers.append(contentsOf: [lanePID, boundedRunnerPID])

            let supervisorPID: Int32
            if scenario.phase == .payload {
                supervisorPID = checkpointFields[2]
            } else {
                supervisorPID = checkpointFields[0]
                #expect(checkpointFields[0] == checkpointFields[1])
            }
            #expect(supervisorPID > 0)
            #expect(getpgid(supervisorPID) == supervisorPID)
            #expect(!ownedProcessIdentifiers.contains(supervisorPID))
            ownedProcessIdentifiers.append(supervisorPID)

            if scenario.phase == .beforeRelease {
                #expect(!FileManager.default.fileExists(atPath: processMarker.path))
            } else {
                let payloadFields = try waitForMatrixSignalMarker(
                    processMarker,
                    expectedCount: 3
                )
                let payloadPID = payloadFields[0]
                let descendantPID = payloadFields[1]
                #expect(payloadFields[2] == supervisorPID)
                #expect(Set(payloadFields).count == 3)
                #expect(!ownedProcessIdentifiers.contains(payloadPID))
                #expect(!ownedProcessIdentifiers.contains(descendantPID))
                #expect(getpgid(descendantPID) == supervisorPID)
                if scenario.phase == .payload {
                    #expect(getpgid(payloadPID) == supervisorPID)
                } else {
                    #expect(!testProcessIsRunning(payloadPID))
                }
                ownedProcessIdentifiers.append(contentsOf: [payloadPID, descendantPID])
            }

            #expect(getpgid(topPID) == topPGID)
            #expect(try running.owner.send(signal: scenario.signal) == 0)
            try waitForMatrixRunnerExit(running)
            let reply = try finishMatrixRunner(running)

            #expect(running.owner.terminationReason == .exit)
            #expect(reply.status == scenario.expectedStatus)
            let killRecords = try readMatrixKillRecords(from: killProbe.records)
            #expect(killRecords.isEmpty)
            expectMatrixOwnedJobSignalEvidence(
                reply.trace,
                parent: topPID,
                edge: .topToLane,
                expectedSignal: matrixSignalName(scenario.signal),
                expectedTarget: lanePID
            )
            expectMatrixOwnedJobSignalEvidence(
                reply.trace,
                parent: lanePID,
                edge: .laneToBounded,
                expectedSignal: matrixSignalName(scenario.signal),
                expectedTarget: boundedRunnerPID
            )
            expectMatrixWaitAuthority(
                reply.trace,
                child: lanePID
            )
            expectMatrixWaitAuthority(
                reply.trace,
                child: boundedRunnerPID
            )
            try expectPreservedSignaledMatrixLaneRoot(
                in: temporaryRoot,
                payloadStarted: scenario.phase != .beforeRelease
            )

            waitForProcessesToExit(ownedProcessIdentifiers)
            guard !ownedProcessIdentifiers.contains(where: testProcessIsRunning) else {
                throw MatrixRunnerHarnessError.processSurvived
            }
            for processIdentifier in ownedProcessIdentifiers {
                #expect(!testProcessIsRunning(processIdentifier))
            }
            runnerFinished = true
        }
    }

    @Test(
        "matrix runner isolates and reaps timed-out jobs without setsid",
        .enabled(
            if: !hasMatrixLaneEnvironment,
            "the outer matrix runner already exercises this lane-invariant test"
        )
    )
    func matrixRunnerIsolatesAndReapsTimedOutJobsWithoutSetsid() throws {
        try withMatrixFixture(tags: requiredTags, executableBinaries: true) { fixture in
            let path = try pathShadowingSetsid(in: fixture.root)
            let probe = fixture.root.appendingPathComponent("process-group-probe")
            try """
            #!/bin/bash
            payload_pid=$$
            supervisor_pgid=$(ps -o pgid= -p "$payload_pid" | tr -d ' ')
            printf '%s %s\n' "$payload_pid" "$supervisor_pgid" \
                >"$LIBTMUX_MATRIX_BINARY_ROOT/process-$LIBTMUX_TMUX_TAG"
            exec sleep 30
            """.write(to: probe, atomically: true, encoding: .utf8)
            try makeExecutable(probe)
            let temporaryRoot = fixture.temporaryRoot

            let reply = try runProcess(
                "/bin/bash",
                [matrixRunnerURL.path, "--", probe.path],
                environment: [
                    "LIBTMUX_MATRIX_BINARY_ROOT": fixture.root.path,
                    "LIBTMUX_MATRIX_MANIFEST": fixture.evidence.path,
                    "LIBTMUX_MATRIX_TIMEOUT_SECONDS": "1",
                    "PATH": path,
                    "TMPDIR": temporaryRoot.path,
                ]
            )

            #expect(reply.status == 1)
            #expect(
                reply.standardError.components(separatedBy: "failed with status 124").count - 1 == 8
            )
            #expect(!FileManager.default.fileExists(atPath: setsidMarker(in: fixture.root).path))

            var processIdentifiers: [Int32] = []
            for tag in requiredTags {
                let record = fixture.root.appendingPathComponent("process-\(tag)")
                let fields = try String(contentsOf: record, encoding: .utf8)
                    .split(whereSeparator: \Character.isWhitespace)
                #expect(fields.count == 2)
                let payloadPID = try #require(Int32(fields[0]))
                let supervisorPID = try #require(Int32(fields[1]))
                #expect(payloadPID != supervisorPID)
                processIdentifiers.append(contentsOf: [payloadPID, supervisorPID])
            }
            waitForProcessesToExit(processIdentifiers)
            for processIdentifier in processIdentifiers {
                #expect(!testProcessIsRunning(processIdentifier))
            }
        }
    }

    @Test("builder rejects root and equal output paths")
    func builderRejectsRootAndEqualOutputPaths() throws {
        try withDisposableDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            try initializeGitRepository(at: source)

            for output in [URL(fileURLWithPath: "/"), source] {
                let reply = try runBuilder(source: source, output: output)
                #expect(reply.status != 0)
                #expect(FileManager.default.fileExists(atPath: source.path))
            }
        }
    }

    @Test("builder rejects an ignored output inside the source before creating it")
    func builderRejectsIgnoredOutputInsideSourceBeforeCreatingIt() throws {
        try withDisposableDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            try initializeGitRepository(at: source, gitignore: "matrix-output/\n")
            let output = source.appendingPathComponent("matrix-output", isDirectory: true)

            let reply = try runBuilder(source: source, output: output)

            #expect(reply.status != 0)
            #expect(reply.standardError.contains("overlap"))
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test("builder resolves symlinks before checking descendant overlap")
    func builderResolvesSymlinksBeforeCheckingDescendantOverlap() throws {
        try withDisposableDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            try initializeGitRepository(at: source, gitignore: "matrix-output/\n")
            let target = source.appendingPathComponent("matrix-output", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("output-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let reply = try runBuilder(source: source, output: link)

            #expect(reply.status != 0)
            #expect(reply.standardError.contains("overlap"))
        }
    }

    @Test("builder rejects an output ancestor before a lane can delete the source")
    func builderRejectsOutputAncestorBeforeLaneCanDeleteSource() throws {
        try withDisposableDirectory { root in
            let output = root.appendingPathComponent("matrix", isDirectory: true)
            let source = output.appendingPathComponent("3.2a", isDirectory: true)
            try initializeGitRepository(at: source, annotatedTag: "3.2a")

            let reply = try runBuilder(source: source, output: output)

            #expect(reply.status != 0)
            #expect(reply.standardError.contains("overlap"))
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(
                FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path))
        }
    }

    @Test("builder detects origin changes made after authentication")
    func builderDetectsOriginChangesMadeAfterAuthentication() throws {
        try withDisposableDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let output = root.appendingPathComponent("output", isDirectory: true)
            let temporaryRoot = root.appendingPathComponent("temporary", isDirectory: true)
            let compiler = root.appendingPathComponent("mutating-compiler")
            try initializeGitRepository(at: source)
            try FileManager.default.createDirectory(
                at: temporaryRoot,
                withIntermediateDirectories: true
            )
            let quotedSource = source.path.replacingOccurrences(of: "'", with: "'\\''")
            try """
            #!/bin/sh
            git -C '\(quotedSource)' remote set-url origin https://example.invalid/tmux.git
            printf 'cc test compiler\\n'
            """.write(to: compiler, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: compiler.path
            )

            let reply = try runBuilder(
                source: source,
                output: output,
                environment: ["CC": compiler.path, "TMPDIR": temporaryRoot.path]
            )

            #expect(reply.status != 0)
            #expect(reply.standardError.contains("tmux source checkout changed during the build"))
        }
    }

    @Test("dirty-source rejection removes every temporary root")
    func dirtySourceRejectionRemovesEveryTemporaryRoot() throws {
        try withDisposableDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let output = root.appendingPathComponent("output", isDirectory: true)
            let temporaryRoot = root.appendingPathComponent("temporary", isDirectory: true)
            try initializeGitRepository(at: source)
            try FileManager.default.createDirectory(
                at: temporaryRoot,
                withIntermediateDirectories: true
            )
            try "dirty\n".write(
                to: source.appendingPathComponent("dirty"),
                atomically: true,
                encoding: .utf8
            )

            let reply = try runBuilder(
                source: source,
                output: output,
                environment: ["TMPDIR": temporaryRoot.path]
            )

            #expect(reply.status != 0)
            #expect(reply.standardError.contains("dirty before the build"))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)
            #expect(leftovers.isEmpty)
        }
    }

    @Test("disposable Git repositories ignore hostile external configuration")
    func disposableGitRepositoriesIgnoreHostileExternalConfiguration() throws {
        try withDisposableDirectory { root in
            let source = root.appendingPathComponent("source", isDirectory: true)
            let hooks = root.appendingPathComponent("hooks", isDirectory: true)
            let templateHooks = root.appendingPathComponent(
                "template/hooks",
                isDirectory: true
            )
            let marker = root.appendingPathComponent("hostile-hook-ran")
            let globalConfig = root.appendingPathComponent("hostile.gitconfig")
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: templateHooks,
                withIntermediateDirectories: true
            )
            let quotedMarker = marker.path.replacingOccurrences(of: "'", with: "'\\''")
            let hostileHook = """
                #!/bin/sh
                printf invoked >'\(quotedMarker)'
                exit 97
                """
            let configuredHook = hooks.appendingPathComponent("pre-commit")
            let templateHook = templateHooks.appendingPathComponent("pre-commit")
            try hostileHook.write(to: configuredHook, atomically: true, encoding: .utf8)
            try hostileHook.write(to: templateHook, atomically: true, encoding: .utf8)
            try makeExecutable(configuredHook)
            try makeExecutable(templateHook)
            try """
            [commit]
                gpgSign = true
            [tag]
                gpgSign = true
            [core]
                hooksPath = \(hooks.path)
            [init]
                templateDir = \(root.appendingPathComponent("template").path)
            """.write(to: globalConfig, atomically: true, encoding: .utf8)

            try initializeGitRepository(
                at: source,
                annotatedTag: "3.2a",
                environment: [
                    "GIT_CONFIG_GLOBAL": globalConfig.path,
                    "GIT_CONFIG_SYSTEM": globalConfig.path,
                ]
            )

            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(
                !FileManager.default.fileExists(
                    atPath: source.appendingPathComponent(".git/hooks/pre-commit").path
                ))
        }
    }

    @Test("a missing lane is rejected")
    func missingLaneIsRejected() throws {
        try withMatrixFixture(tags: Array(requiredTags.dropLast())) { fixture in
            try expectMatrixError(
                .laneOrderMismatch(expected: requiredTags, actual: Array(requiredTags.dropLast())),
                fixture: fixture
            )
        }
    }

    @Test("a duplicated lane is rejected")
    func duplicatedLaneIsRejected() throws {
        let tags = Array(requiredTags.dropLast()) + ["3.7a"]

        try withMatrixFixture(tags: tags) { fixture in
            try expectMatrixError(
                .laneOrderMismatch(expected: requiredTags, actual: tags),
                fixture: fixture
            )
        }
    }

    @Test("an unordered lane list is rejected")
    func unorderedLaneListIsRejected() throws {
        var tags = requiredTags
        tags.swapAt(1, 2)

        try withMatrixFixture(tags: tags) { fixture in
            try expectMatrixError(
                .laneOrderMismatch(expected: requiredTags, actual: tags),
                fixture: fixture
            )
        }
    }

    @Test("reported tmux version must agree with its raw tag")
    func reportedVersionMustMatchTag() throws {
        try withMatrixFixture(tags: requiredTags, reportedVersions: ["3.7": "tmux 3.7a"]) {
            fixture in
            try expectMatrixError(
                .reportedVersionMismatch(tag: "3.7", reported: "tmux 3.7a"),
                fixture: fixture
            )
        }
    }

    @Test("binary contents must agree with the evidence hash")
    func binaryHashMustMatchEvidence() throws {
        try withMatrixFixture(tags: requiredTags, changedBinaryTag: "3.5") { fixture in
            try expectMatrixError(
                .binaryHashMismatch(
                    tag: "3.5",
                    expected: emptySHA256,
                    actual: changedSHA256
                ),
                fixture: fixture
            )
        }
    }

    @Test("every evidence entry requires a peeled source object")
    func peeledSourceObjectIsRequired() throws {
        try withMatrixFixture(tags: requiredTags, missingSourceObjectTag: "3.3a") { fixture in
            try expectMatrixError(
                .missingPeeledSourceObject(tag: "3.3a"),
                fixture: fixture
            )
        }
    }

    @Test("raw point-release suffixes remain distinct")
    func rawPointReleaseSuffixesRemainDistinct() throws {
        try withMatrixFixture(tags: requiredTags) { fixture in
            let matrix = try loadMatrix(from: fixture)
            let raw = try #require(matrix.lanes.first { $0.rawTag == "3.7" })
            let firstPatch = try #require(matrix.lanes.first { $0.rawTag == "3.7a" })
            let secondPatch = try #require(matrix.lanes.first { $0.rawTag == "3.7b" })

            #expect(raw.numericVersion == TmuxNumericVersion(major: 3, minor: 7))
            #expect(raw.suffix == nil)
            #expect(firstPatch.numericVersion == raw.numericVersion)
            #expect(firstPatch.suffix == "a")
            #expect(secondPatch.numericVersion == raw.numericVersion)
            #expect(secondPatch.suffix == "b")
        }
    }
}

private struct MatrixFixture {
    let root: URL
    let evidence: URL
    let temporaryRoot: URL
}

private let requiredTags = ["3.2a", "3.3a", "3.4", "3.5", "3.6", "3.7", "3.7a", "3.7b"]
private let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
private let changedSHA256 = "7f8b1dfc466b6249f06cbe55c9174df2578e7754da793fded244ef5cba2a38f1"
private let validRefsSHA256 = "sha256:" + String(repeating: "1", count: 64)
private let validIndexSHA256 = "sha256:" + String(repeating: "2", count: 64)
private let hasMatrixLaneEnvironment =
    ProcessInfo.processInfo.environment["LIBTMUX_TMUX_TAG"] != nil

enum MatrixSignalPhase: String, Equatable, Sendable {
    case beforeRelease = "before-release"
    case payload
    case afterStatus = "after-status"
}

enum MatrixPostSpawnFailureEdge: String, CaseIterable, Sendable {
    case laneToBounded = "lane-to-bounded"
    case topToLane = "top-to-lane"

    var expectedStatus: Int32 {
        switch self {
        case .laneToBounded:
            1
        case .topToLane:
            92
        }
    }

    var reapedStatusVariable: String {
        switch self {
        case .laneToBounded:
            "reaped_bounded_status"
        case .topToLane:
            "reaped_lane_status"
        }
    }

    var captureAssignment: String {
        switch self {
        case .laneToBounded:
            "bounded_child=$!"
        case .topToLane:
            "lane_child=$!"
        }
    }

    var captureFailureStatus: Int32 {
        switch self {
        case .laneToBounded:
            1
        case .topToLane:
            125
        }
    }
}

struct MatrixSignalScenario: Sendable {
    let signal: Int32
    let expectedStatus: Int32
    let phase: MatrixSignalPhase
}

private struct MatrixKillProbe {
    let path: String
    let records: URL
}

private struct MatrixKillRecord: Equatable {
    let parent: Int32
    let signal: String
    let target: Int32
    let status: Int32

    init(parent: Int32, signal: String, target: Int32, status: Int32 = 0) {
        self.parent = parent
        self.signal = signal
        self.target = target
        self.status = status
    }
}

private struct MatrixOwnedJobSignal: Equatable {
    let signal: String
    let jobSpec: String
}

private struct MatrixProcessAssignment: Equatable {
    let owner: Int32
    let processIdentifier: Int32
}

private let matrixSignalScenarios = [SIGHUP, SIGINT, SIGTERM].flatMap { signal in
    [MatrixSignalPhase.beforeRelease, .payload, .afterStatus].map { phase in
        MatrixSignalScenario(signal: signal, expectedStatus: 128 + signal, phase: phase)
    }
}

private let matrixBlockingSignalProbeBody = #"""
    trap '' HUP INT TERM
    bash -c 'trap "" HUP INT TERM; while :; do /bin/sleep 1; done' "$1" &
    descendant=$!
    supervisor=$(ps -o pgid= -p "$$" | tr -d ' ')
    record="$LIBTMUX_MATRIX_SIGNAL_MARKER"
    printf '%s %s %s\n' "$$" "$descendant" "$supervisor" >"$record.pending"
    mv "$record.pending" "$record"
    while :; do /bin/sleep 1; done
    """#

private let matrixCompletedSignalProbeBody = #"""
    bash -c 'trap "" HUP INT TERM; while :; do /bin/sleep 1; done' "$1" &
    descendant=$!
    supervisor=$(ps -o pgid= -p "$$" | tr -d ' ')
    record="$LIBTMUX_MATRIX_SIGNAL_MARKER"
    printf '%s %s %s\n' "$$" "$descendant" "$supervisor" >"$record.pending"
    mv "$record.pending" "$record"
    exit 23
    """#

private enum MatrixRunnerHarnessError: Error {
    case fifoCreationFailed(Int32)
    case launchAuthenticationFailed(
        processIdentifier: pid_t,
        processGroupIdentifier: pid_t,
        recoveryTokenPresent: Bool
    )
    case launchRollbackFailed(pid_t)
    case markerTimedOut
    case processGroupAuthenticationFailed
    case runnerTimedOut
    case processSurvived
    case spawnFailed(Int32)
    case temporaryDirectoryCreationFailed(Int32)
    case waitFailed(Int32)
}

private struct RunningMatrixRunner {
    let owner: MatrixRunnerProcessOwner
    let standardOutputURL: URL
    let standardErrorURL: URL
    let xtraceURL: URL
}

private struct ScriptReply {
    let standardOutput: String
    let standardError: String
    let trace: String
    let status: Int32
}

private struct DirectGateHarness {
    let homeSentinel: String
    let mainRecord: URL
    let probeDirectory: URL
    let registryRecord: URL
    let shims: URL
}

struct DirectLaneEnvironmentCase: Sendable {
    let environment: [String: String]
}

private let directLaneEnvironmentCases = [
    DirectLaneEnvironmentCase(
        environment: ["LIBTMUX_TMUX_BIN": "/fixture/tmux"]
    ),
    DirectLaneEnvironmentCase(
        environment: [
            "LIBTMUX_TMUX_BIN": "/fixture/tmux",
            "LIBTMUX_TMUX_TAG": "3.7b",
        ]
    ),
    DirectLaneEnvironmentCase(
        environment: [
            "LIBTMUX_MATRIX_ROOT": "/fixture/root",
            "LIBTMUX_TMUX_BIN": "/fixture/tmux",
            "LIBTMUX_TMUX_TAG": "3.7b",
        ]
    ),
]

// The deepest endpoint a lane binds, matching the runner's own reservation:
// the sandbox TMPDIR child, a test-owned scope directory, then the fixture run
// directory and its socket — "/tmp/lt-XXXXXXXX/f-<22-byte nonce>/s/s".
private let fixtureSocketPathSuffixByteCount = 45

private func expectMatrixError(_ expected: TmuxMatrixError, fixture: MatrixFixture) throws {
    do {
        _ = try loadMatrix(from: fixture)
        Issue.record("matrix validation unexpectedly succeeded")
    } catch let error as TmuxMatrixError {
        #expect(error == expected)
    } catch {
        Issue.record("matrix validation threw an unexpected error: \(error)")
    }
}

private func loadMatrix(from fixture: MatrixFixture) throws -> TmuxMatrix {
    try TmuxMatrix.load(
        laneDeclarationAt: laneDeclarationURL,
        evidenceAt: fixture.evidence,
        binariesAt: fixture.root
    )
}

private func withMatrixFixture(
    tags: [String],
    reportedVersions: [String: String] = [:],
    changedBinaryTag: String? = nil,
    missingSourceObjectTag: String? = nil,
    sourceDigest: String? = nil,
    executableBinaries: Bool = false,
    body: (MatrixFixture) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("libtmux-matrix-tests-\(UUID().uuidString)", isDirectory: true)
    let temporaryRoot = try makeShortMatrixTemporaryRoot()
    defer {
        try? FileManager.default.removeItem(at: temporaryRoot)
        try? FileManager.default.removeItem(at: root)
    }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var entries: [[String: Any]] = []

    for tag in tags {
        let binary =
            root
            .appendingPathComponent(tag, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("tmux")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = tag == changedBinaryTag ? Data("changed\n".utf8) : Data()
        try contents.write(to: binary)
        if executableBinaries {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: binary.path
            )
        }

        var entry: [String: Any] = [
            "tag": tag,
            "tagObject": "85893888497c5077979bc7557fb970ee5e3d13d9",
            "binaryPath": "\(tag)/bin/tmux",
            "binarySHA256": emptySHA256,
            "reportedVersion": reportedVersions[tag] ?? "tmux \(tag)",
            "compilerIdentity": "cc test compiler",
            "buildStatus": "passed",
        ]
        if tag != missingSourceObjectTag {
            entry["peeledSourceObject"] = "3b929f332aafa7f1080eacc31feb11ffbb1d1841"
        }
        entries.append(entry)
    }

    let manifest: [String: Any] = [
        "documentKind": "libtmux.tmux-matrix-manifest",
        "schemaVersion": 1,
        "source": [
            "originURL": "https://github.com/tmux/tmux.git",
            "head": "e802909de06012a4df6209d55e86487c56223163",
            "initialStatus": "",
            "finalStatus": "",
            "initialRefsSHA256": sourceDigest ?? validRefsSHA256,
            "finalRefsSHA256": sourceDigest ?? validRefsSHA256,
            "initialIndexSHA256": sourceDigest ?? validIndexSHA256,
            "finalIndexSHA256": sourceDigest ?? validIndexSHA256,
            "sourceUnchanged": true,
        ],
        "lanes": entries,
    ]
    let evidence = root.appendingPathComponent("manifest.json")
    let data = try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: evidence)

    try body(
        MatrixFixture(
            root: root,
            evidence: evidence,
            temporaryRoot: temporaryRoot
        )
    )
}

private func makeShortMatrixTemporaryRoot() throws -> URL {
    var template = Array("/tmp/m.XXXXXX".utf8CString)
    let result = template.withUnsafeMutableBufferPointer { buffer in
        mkdtemp(buffer.baseAddress!)
    }
    guard result != nil else {
        throw MatrixRunnerHarnessError.temporaryDirectoryCreationFailed(errno)
    }
    let pathBytes = template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self), isDirectory: true)
}

private func withDisposableDirectory(body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("libtmux-builder-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try body(root)
}

private func initializeGitRepository(
    at source: URL,
    gitignore: String? = nil,
    annotatedTag: String? = nil,
    environment: [String: String] = [:]
) throws {
    let emptyTemplate = source.deletingLastPathComponent()
        .appendingPathComponent("git-template-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: emptyTemplate) }
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: emptyTemplate, withIntermediateDirectories: true)
    try "fixture\n".write(
        to: source.appendingPathComponent("README"),
        atomically: true,
        encoding: .utf8
    )
    if let gitignore {
        try gitignore.write(
            to: source.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
    }

    var gitEnvironment = ProcessInfo.processInfo.environment
    gitEnvironment.merge(environment) { _, replacement in replacement }
    for key in gitEnvironment.keys
    where key == "GIT_CONFIG"
        || key == "GIT_CONFIG_PARAMETERS"
        || key == "GIT_TEMPLATE_DIR"
        || key.hasPrefix("GIT_CONFIG_KEY_")
        || key.hasPrefix("GIT_CONFIG_VALUE_")
    {
        gitEnvironment.removeValue(forKey: key)
    }
    gitEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
    gitEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    gitEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    gitEnvironment["GIT_CONFIG_COUNT"] = "0"
    gitEnvironment["GIT_TEMPLATE_DIR"] = emptyTemplate.path

    let gitConfiguration = [
        "-c", "commit.gpgSign=false",
        "-c", "tag.gpgSign=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "init.templateDir=\(emptyTemplate.path)",
    ]
    func git(_ arguments: [String]) throws -> ScriptReply {
        try runProcess(
            "/usr/bin/env",
            ["git"] + gitConfiguration + arguments,
            environment: gitEnvironment,
            replacingEnvironment: true
        )
    }

    try requireSuccess(
        try git(["init", "-q", "--template=\(emptyTemplate.path)", source.path])
    )
    try requireSuccess(
        try git(["-C", source.path, "config", "user.name", "Matrix Tests"])
    )
    try requireSuccess(
        try git(["-C", source.path, "config", "user.email", "matrix@example.invalid"])
    )
    try requireSuccess(
        try git([
            "-C", source.path, "remote", "add", "origin",
            "https://github.com/tmux/tmux.git",
        ])
    )
    try requireSuccess(try git(["-C", source.path, "add", "."]))
    try requireSuccess(
        try git(["-C", source.path, "commit", "-q", "-m", "fixture"])
    )
    if let annotatedTag {
        try requireSuccess(
            try git(["-C", source.path, "tag", "-a", annotatedTag, "-m", annotatedTag])
        )
    }
}

private func pathShadowingSetsid(in root: URL) throws -> String {
    let shims = root.appendingPathComponent("shims", isDirectory: true)
    try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
    let setsid = shims.appendingPathComponent("setsid")
    let quotedMarker = setsidMarker(in: root).path.replacingOccurrences(of: "'", with: "'\\''")
    try """
    #!/bin/sh
    : >'\(quotedMarker)'
    exit 97
    """.write(to: setsid, atomically: true, encoding: .utf8)
    try makeExecutable(setsid)
    return shims.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
}

private func setsidMarker(in root: URL) -> URL {
    root.appendingPathComponent("setsid-invoked")
}

private func pathAcceleratingMatrixTimeout(in root: URL) throws -> String {
    let shims = root.appendingPathComponent("timeout-shims", isDirectory: true)
    try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
    let sleep = shims.appendingPathComponent("sleep")
    try """
    #!/bin/sh
    exec /bin/sleep 0.25
    """.write(to: sleep, atomically: true, encoding: .utf8)
    try makeExecutable(sleep)
    return shims.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
}

private func pathEmittingTraceShapedMatrixStandardError(in root: URL) throws -> String {
    let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let shims = root.appendingPathComponent("trace-shaped-stderr-shims", isDirectory: true)
    try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: false)

    var utilityWasFound = false
    for utility in ["sha256sum", "shasum"] {
        guard let executable = matrixExecutable(named: utility, searchPath: searchPath) else {
            continue
        }
        utilityWasFound = true
        let shim = shims.appendingPathComponent(utility)
        try """
        #!/bin/sh
        printf '+TRACE: failure\\n' >&2
        exec \(executable.path) "$@"
        """.write(to: shim, atomically: true, encoding: .utf8)
        try makeExecutable(shim)
    }
    guard utilityWasFound else {
        throw MatrixRunnerHarnessError.spawnFailed(ENOENT)
    }
    return shims.path + ":" + searchPath
}

private func matrixExecutable(named name: String, searchPath: String) -> URL? {
    for component in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
        let directory = component.isEmpty ? "." : String(component)
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func makeMatrixKillProbe(in root: URL) throws -> MatrixKillProbe {
    let shims = root.appendingPathComponent("kill-probe-shims", isDirectory: true)
    let records = root.appendingPathComponent("kill-probe-records", isDirectory: true)
    try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
    let kill = shims.appendingPathComponent("kill")
    try #"""
    #!/bin/bash
    set -uo pipefail
    [[ $# == 3 && $1 == "-s" && $2 =~ ^[A-Z]+$ && $3 =~ ^[1-9][0-9]*$ ]] || exit 64
    records=${LIBTMUX_MATRIX_KILL_TRACE_DIRECTORY:-}
    [[ -d "$records" && ! -L "$records" ]] || exit 65
    /bin/kill "$@"
    status=$?
    pending="$records/kill.$PPID.$$.$RANDOM.pending"
    record=${pending%.pending}
    (umask 077; set -C; printf '%s %s %s %s\n' \
        "$PPID" "$2" "$3" "$status" >"$pending") || exit 65
    mv "$pending" "$record" || exit 65
    exit "$status"
    """#.write(to: kill, atomically: true, encoding: .utf8)
    try makeExecutable(kill)
    let path = shims.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
    return MatrixKillProbe(path: path, records: records)
}

private func makeExecutable(_ file: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: file.path
    )
}

private func makeDirectGateHarness(
    in root: URL,
    mainStatus: Int32
) throws -> DirectGateHarness {
    let shims = root.appendingPathComponent("direct-gate-shims", isDirectory: true)
    let records = root.appendingPathComponent("direct-gate-records", isDirectory: true)
    let probeDirectory = root.appendingPathComponent("direct-gate-probes", isDirectory: true)
    for directory in [shims, records, probeDirectory] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
    }

    let mainRecord = records.appendingPathComponent("main")
    let registryRecord = records.appendingPathComponent("registry")
    let homeSentinel = "/caller-home-must-remain"
    let swift = shims.appendingPathComponent("swift")
    let quotedProbes = shellSingleQuoted(probeDirectory.path)
    try #"""
    #!/bin/bash
    set -euo pipefail

    mode_of() {
        stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
    }

    if [[ ${1:-} == build ]]; then
        if [[ ${4:-} == --show-bin-path ]]; then
            printf '%s\n' '\#(quotedProbes)'
        fi
        exit 0
    fi

    [[ ${1:-} == test ]] || exit 64
    if [[ ${LIBTMUX_REGISTRY_IDENTITY_PROBE:-0} == 1 ]]; then
        record='\#(shellSingleQuoted(registryRecord.path))'
        [[ ! -e "$record" && ! -L "$record" ]] || exit 96
        {
            printf 'tmp=%s\n' "$TMPDIR"
            printf 'mode=%s\n' "$(mode_of "$TMPDIR")"
            printf 'home=%s\n' "${HOME-<unset>}"
        } >"$record.pending"
        mv "$record.pending" "$record"
        printf 'Caught error: duplicateCaseIdentity\n'
        printf 'Test run with 1 test in 1 suite failed now with 1 issue.\n'
        printf 'with 2 test cases failed now with 1 issue.\n'
        exit 1
    fi

    record='\#(shellSingleQuoted(mainRecord.path))'
    [[ ! -e "$record" && ! -L "$record" ]] || exit 96
    root=$LIBTMUX_MATRIX_ROOT
    parent=${root%/*}
    {
        printf 'tag=%s\n' "$LIBTMUX_TMUX_TAG"
        printf 'binary=%s\n' "$LIBTMUX_TMUX_BIN"
        printf 'root=%s\n' "$root"
        printf 'manifest=%s\n' "$LIBTMUX_MATRIX_MANIFEST"
        printf 'binary_root=%s\n' "$LIBTMUX_MATRIX_BINARY_ROOT"
        printf 'pty_probe=%s\n' "$LIBTMUX_PTY_CLIENT_PROBE"
        printf 'fixture_owner_helper=%s\n' "$LIBTMUX_FIXTURE_OWNER_HELPER"
        printf 'home=%s\n' "${HOME-<unset>}"
        printf 'tmp=%s\n' "$TMPDIR"
        printf 'root_mode=%s\n' "$(mode_of "$root")"
        printf 'parent_mode=%s\n' "$(mode_of "$parent")"
    } >"$record.pending"
    mv "$record.pending" "$record"
    : >"$root/direct-marker"
    exit \#(mainStatus)
    """#.write(to: swift, atomically: true, encoding: .utf8)
    try makeExecutable(swift)

    let uv = shims.appendingPathComponent("uv")
    try #"""
    #!/bin/sh
    exec /bin/cat '\#(shellSingleQuoted(pythonReplyOracleURL.path))'
    """#.write(to: uv, atomically: true, encoding: .utf8)
    try makeExecutable(uv)

    for name in [
        "fixture-owner-helper",
        "process-probe",
        "pty-client-probe",
        "sigpipe-probe",
    ] {
        let probe = probeDirectory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(
            to: probe,
            atomically: true,
            encoding: .utf8
        )
        try makeExecutable(probe)
    }

    return DirectGateHarness(
        homeSentinel: homeSentinel,
        mainRecord: mainRecord,
        probeDirectory: probeDirectory,
        registryRecord: registryRecord,
        shims: shims
    )
}

private func runDirectFixtureGate(
    fixture: MatrixFixture,
    harness: DirectGateHarness
) throws -> ScriptReply {
    let hostileTemporaryRoot = fixture.root.appendingPathComponent(
        String(repeating: "ambient-temporary-root-is-too-long-", count: 4),
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: hostileTemporaryRoot,
        withIntermediateDirectories: false
    )
    var environment = minimalScriptEnvironment(shims: harness.shims)
    environment.merge(
        [
            "HOME": harness.homeSentinel,
            "LIBTMUX_MATRIX_BINARY_ROOT": fixture.root.path,
            "LIBTMUX_MATRIX_MANIFEST": fixture.evidence.path,
            "TMPDIR": hostileTemporaryRoot.path,
        ]
    ) { _, replacement in replacement }
    return try runProcess(
        "/bin/bash",
        [testSpikesURL.path, "--filter", "FixtureBakeoffTests"],
        environment: environment,
        replacingEnvironment: true
    )
}

private func minimalScriptEnvironment(shims: URL) -> [String: String] {
    [
        "HOME": "/script-test-home",
        "LC_ALL": "C",
        "PATH": shims.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
    ]
}

private func readKeyValueRecord(_ record: URL) throws -> [String: String] {
    let contents = try String(contentsOf: record, encoding: .utf8)
    return try contents.split(whereSeparator: \Character.isNewline).reduce(into: [:]) {
        fields,
        line in
        guard let separator = line.firstIndex(of: "=") else {
            throw TmuxMatrixError.invalidEvidence("invalid direct gate record")
        }
        let key = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        guard fields.updateValue(value, forKey: key) == nil else {
            throw TmuxMatrixError.invalidEvidence("duplicate direct gate record key")
        }
    }
}

private func shellSingleQuoted(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
}

private func makeMatrixLaneProbe(named name: String, body: String, in root: URL) throws -> URL {
    let probe = root.appendingPathComponent(name)
    try """
    #!/bin/bash
    set -euo pipefail
    printf '%s\\n' "$LIBTMUX_TMUX_TAG" >"$LIBTMUX_MATRIX_ROOT/lane-artifact"
    \(body)
    """.write(to: probe, atomically: true, encoding: .utf8)
    try makeExecutable(probe)
    return probe
}

private func makeMatrixCaptureFailureBashEnvironment(in root: URL) throws -> URL {
    let environment = root.appendingPathComponent("capture-failure.bash")
    let script = #"""
        set -T
        trap '
            if [[ ${BASH_COMMAND:-} == "$LIBTMUX_TEST_CAPTURE_ASSIGNMENT" \
                && ${tag:-} == "$LIBTMUX_TEST_CAPTURE_TAG" ]]; then
                trap - DEBUG
                injected_original=$!
                capture_owned_job_handle() {
                    local expected=$1
                    [[ $expected == "$injected_original" ]] || return 2
                    bash -c '\''
                        trap "" HUP INT TERM
                        kill -STOP $$
                        while :; do sleep 1; done
                    '\'' "$LIBTMUX_TEST_DECOY_TOKEN" &
                    decoy=$!
                    decoy_state=""
                    attempt=0
                    while (( attempt < 30000 )); do
                        decoy_state=$(LC_ALL=C ps -o stat= -p "$decoy" 2>/dev/null || true)
                        [[ $decoy_state == *T* ]] && break
                        sleep 0.001
                        (( attempt += 1 ))
                    done
                    [[ $decoy_state == *T* ]] || return 2
                    pending="$LIBTMUX_TEST_CAPTURE_MARKER.pending.$$-$RANDOM"
                    (umask 077; set -C; printf "%s %s\n" \
                        "$injected_original" "$decoy" >"$pending") || return 2
                    mv "$pending" "$LIBTMUX_TEST_CAPTURE_MARKER" || return 2
                    return 1
                }
            fi
        ' DEBUG
        """#
    try Data(script.utf8).write(to: environment)
    return environment
}

private func runMatrixRunner(
    fixture: MatrixFixture,
    command: URL,
    temporaryRoot: URL,
    environment: [String: String] = [:],
    selectedTag: String? = nil
) throws -> ScriptReply {
    let recoveryToken = "libtmux-matrix-owner-\(UUID().uuidString)"
    let xtrace = fixture.root.appendingPathComponent("matrix-xtrace-\(UUID().uuidString)")
    var runnerEnvironment = [
        "LIBTMUX_MATRIX_BINARY_ROOT": fixture.root.path,
        "LIBTMUX_MATRIX_MANIFEST": fixture.evidence.path,
        "LIBTMUX_MATRIX_RECOVERY_TOKEN": recoveryToken,
        "TMPDIR": temporaryRoot.path,
    ]
    runnerEnvironment.merge(environment) { _, replacement in replacement }
    let running = try launchMatrixRunner(
        fixture: fixture,
        command: command,
        temporaryRoot: temporaryRoot,
        environment: runnerEnvironment,
        commandArguments: [recoveryToken],
        xtrace: xtrace,
        runnerArguments: selectedTag.map { ["--lane", $0] } ?? []
    )
    var runnerFinished = false
    defer {
        if !runnerFinished {
            terminateMatrixRunner(running, recoveryToken: recoveryToken)
        }
    }
    try running.owner.waitForExit(timeout: .seconds(45))
    let reply = try finishMatrixRunner(running)
    runnerFinished = true
    return reply
}

private func makeMatrixSignalFIFO(at gate: URL) throws {
    let result = gate.path.withCString { path in
        #if canImport(Darwin)
            Darwin.mkfifo(path, 0o600)
        #elseif canImport(Glibc)
            Glibc.mkfifo(path, 0o600)
        #else
            -1
        #endif
    }
    guard result == 0 else {
        throw MatrixRunnerHarnessError.fifoCreationFailed(errno)
    }
}

private func waitForMatrixSignalMarker(_ marker: URL, expectedCount: Int) throws -> [Int32] {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if let contents = try? String(contentsOf: marker, encoding: .utf8) {
            let fields = contents.split(whereSeparator: \Character.isWhitespace)
            if fields.count == expectedCount {
                let identifiers = fields.compactMap { Int32($0) }
                if identifiers.count == expectedCount {
                    return identifiers
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    throw MatrixRunnerHarnessError.markerTimedOut
}

private func launchMatrixRunner(
    fixture: MatrixFixture,
    command: URL,
    temporaryRoot: URL,
    environment: [String: String],
    commandArguments: [String],
    xtrace: URL,
    runnerArguments: [String] = []
) throws -> RunningMatrixRunner {
    guard let recoveryToken = environment["LIBTMUX_MATRIX_RECOVERY_TOKEN"] else {
        throw MatrixRunnerHarnessError.processGroupAuthenticationFailed
    }
    let standardOutputURL = xtrace.appendingPathExtension("stdout")
    let standardErrorURL = xtrace.appendingPathExtension("stderr")
    var childEnvironment = ProcessInfo.processInfo.environment
    childEnvironment.merge(
        [
            "LIBTMUX_MATRIX_BINARY_ROOT": fixture.root.path,
            "LIBTMUX_MATRIX_MANIFEST": fixture.evidence.path,
            "TMPDIR": temporaryRoot.path,
        ]
    ) { _, replacement in replacement }
    childEnvironment.merge(environment) { _, replacement in replacement }
    childEnvironment["PS4"] = "+TRACE:${matrix_trace_owner:-0}:${FUNCNAME[0]:-main}: "
    childEnvironment["BASH_XTRACEFD"] = String(matrixXtraceDescriptor)
    let processIdentifier = try spawnMatrixRunner(
        arguments: ["-x", matrixRunnerURL.path] + runnerArguments + ["--", command.path]
            + commandArguments,
        environment: childEnvironment,
        standardOutput: standardOutputURL,
        standardError: standardErrorURL,
        xtrace: xtrace
    )
    let owner = MatrixRunnerProcessOwner(
        processIdentifier: processIdentifier,
        recoveryToken: recoveryToken
    )
    do {
        try owner.authenticateAfterSpawn()
    } catch {
        guard owner.stopAndReap() else {
            throw MatrixRunnerHarnessError.launchRollbackFailed(processIdentifier)
        }
        throw error
    }
    return RunningMatrixRunner(
        owner: owner,
        standardOutputURL: standardOutputURL,
        standardErrorURL: standardErrorURL,
        xtraceURL: xtrace
    )
}

private final class MatrixRunnerProcessOwner {
    let processIdentifier: pid_t
    private let recoveryToken: String
    private var rawWaitStatus: Int32?
    private var terminalStatusPending = false

    init(processIdentifier: pid_t, recoveryToken: String) {
        self.processIdentifier = processIdentifier
        self.recoveryToken = recoveryToken
    }

    var terminationReason: Process.TerminationReason? {
        guard let rawWaitStatus else { return nil }
        return rawWaitStatus & 0x7f == 0 ? .exit : .uncaughtSignal
    }

    func authenticateAfterSpawn() throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while true {
            if authenticatesProcessGroup() { return }
            if try observeTerminalStatus() { return }
            guard ContinuousClock.now < deadline else { break }
            Thread.sleep(forTimeInterval: 0.002)
        }
        throw MatrixRunnerHarnessError.launchAuthenticationFailed(
            processIdentifier: processIdentifier,
            processGroupIdentifier: getpgid(processIdentifier),
            recoveryTokenPresent: matrixProcessHasExactArgument(
                processIdentifier,
                recoveryToken
            )
        )
    }

    func send(signal: Int32) throws -> Int32 {
        guard try !pollExit(), authenticatesProcessGroup() else {
            throw MatrixRunnerHarnessError.processGroupAuthenticationFailed
        }
        return sendMatrixSignal(signal, to: processIdentifier)
    }

    func waitForExit(timeout: Duration) throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try pollExit() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard try pollExit() else {
            throw MatrixRunnerHarnessError.runnerTimedOut
        }
    }

    func exitStatus() throws -> Int32 {
        guard let rawWaitStatus else {
            throw MatrixRunnerHarnessError.waitFailed(ECHILD)
        }
        let signal = rawWaitStatus & 0x7f
        return signal == 0 ? (rawWaitStatus >> 8) & 0xff : 128 + signal
    }

    func stopAndReap() -> Bool {
        do {
            if try pollExit() { return true }
        } catch {
            return false
        }

        guard signalOwnedDirectChild(SIGTERM), signalOwnedDirectChild(SIGCONT) else {
            return false
        }
        if waitForReap(until: ContinuousClock.now + .seconds(2)) { return true }
        guard signalOwnedDirectChild(SIGKILL) else { return false }
        return waitForReap(until: ContinuousClock.now + .seconds(2))
    }

    private func authenticatesProcessGroup() -> Bool {
        rawWaitStatus == nil
            && !terminalStatusPending
            && getpgid(processIdentifier) == processIdentifier
            && matrixProcessHasExactArgument(processIdentifier, recoveryToken)
    }

    private func signalOwnedDirectChild(_ signal: Int32) -> Bool {
        do {
            if try observeTerminalStatus() { return true }
        } catch {
            return false
        }

        // Sole wait authority keeps this PID reserved until pollExit performs the reap.
        if sendMatrixSignal(signal, to: processIdentifier) == 0 { return true }
        guard errno == ESRCH else { return false }
        return (try? observeTerminalStatus()) == true
    }

    private func waitForReap(until deadline: ContinuousClock.Instant) -> Bool {
        while ContinuousClock.now < deadline {
            do {
                if try pollExit() { return true }
            } catch {
                return false
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (try? pollExit()) == true
    }

    private func pollExit() throws -> Bool {
        if rawWaitStatus != nil { return true }
        guard try observeTerminalStatus() else { return false }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            errno = 0
            result = waitpid(processIdentifier, &status, 0)
        } while result < 0 && errno == EINTR
        if result == processIdentifier {
            rawWaitStatus = status
            return true
        }
        throw MatrixRunnerHarnessError.waitFailed(errno)
    }

    private func observeTerminalStatus() throws -> Bool {
        if terminalStatusPending { return true }
        var information = siginfo_t()
        var result: Int32
        repeat {
            errno = 0
            result = waitid(
                P_PID,
                id_t(processIdentifier),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            )
        } while result < 0 && errno == EINTR
        guard result == 0 else {
            throw MatrixRunnerHarnessError.waitFailed(errno)
        }
        guard matrixSignalInfoProcessIdentifier(information) == processIdentifier else {
            return false
        }
        terminalStatusPending = true
        return true
    }
}

private func matrixSignalInfoProcessIdentifier(_ information: siginfo_t) -> pid_t {
    #if os(Linux)
        information._sifields._sigchld.si_pid
    #elseif canImport(Darwin)
        information.si_pid
    #else
        0
    #endif
}

private func spawnMatrixRunner(
    arguments: [String],
    environment: [String: String],
    standardOutput: URL,
    standardError: URL,
    xtrace: URL
) throws -> pid_t {
    let outputDescriptor = try openMatrixCaptureDescriptor(standardOutput.path)
    let errorDescriptor: Int32
    do {
        errorDescriptor = try openMatrixCaptureDescriptor(standardError.path)
    } catch {
        _ = close(outputDescriptor)
        throw error
    }
    let traceDescriptor: Int32
    do {
        traceDescriptor = try openMatrixCaptureDescriptor(xtrace.path)
    } catch {
        _ = close(outputDescriptor)
        _ = close(errorDescriptor)
        throw error
    }
    defer {
        _ = close(outputDescriptor)
        _ = close(errorDescriptor)
        _ = close(traceDescriptor)
    }

    #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
    #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
    #endif
    var actionsInitialized = false
    var attributesInitialized = false
    defer {
        if actionsInitialized { _ = posix_spawn_file_actions_destroy(&actions) }
        if attributesInitialized { _ = posix_spawnattr_destroy(&attributes) }
    }

    var code = posix_spawn_file_actions_init(&actions)
    guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
    actionsInitialized = true
    code = posix_spawnattr_init(&attributes)
    guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
    attributesInitialized = true

    for (source, destination) in [
        (outputDescriptor, STDOUT_FILENO),
        (errorDescriptor, STDERR_FILENO),
        (traceDescriptor, matrixXtraceDescriptor),
    ] {
        code = posix_spawn_file_actions_adddup2(&actions, source, destination)
        guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
    }
    #if canImport(Darwin)
        for descriptor in Set([outputDescriptor, errorDescriptor, traceDescriptor])
        where descriptor > matrixXtraceDescriptor {
            code = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
        }
    #else
        code = posix_spawn_file_actions_addclosefrom_np(&actions, matrixXtraceDescriptor + 1)
        guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
    #endif

    var emptyMask = sigset_t()
    guard sigemptyset(&emptyMask) == 0 else {
        throw MatrixRunnerHarnessError.spawnFailed(errno)
    }
    code = posix_spawnattr_setsigmask(&attributes, &emptyMask)
    guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
    var defaultSignals = sigset_t()
    guard sigemptyset(&defaultSignals) == 0,
        sigaddset(&defaultSignals, SIGHUP) == 0,
        sigaddset(&defaultSignals, SIGINT) == 0,
        sigaddset(&defaultSignals, SIGTERM) == 0
    else {
        throw MatrixRunnerHarnessError.spawnFailed(errno)
    }
    code = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
    code = posix_spawnattr_setpgroup(&attributes, 0)
    guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
    var flags =
        Int16(POSIX_SPAWN_SETSIGMASK)
        | Int16(POSIX_SPAWN_SETSIGDEF)
        | Int16(POSIX_SPAWN_SETPGROUP)
    #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif
    code = posix_spawnattr_setflags(&attributes, flags)
    guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }

    let executable = "/bin/bash"
    let argv = [executable] + arguments
    let environmentValues = environment.keys.sorted().compactMap { key in
        environment[key].map { "\(key)=\($0)" }
    }
    var processIdentifier: pid_t = 0
    code = withMatrixCStringArray(argv) { argumentPointers in
        withMatrixCStringArray(environmentValues) { environmentPointers in
            posix_spawn(
                &processIdentifier,
                executable,
                &actions,
                &attributes,
                argumentPointers,
                environmentPointers
            )
        }
    }
    guard code == 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
    return processIdentifier
}

private func openMatrixCaptureDescriptor(_ path: String) throws -> Int32 {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw MatrixRunnerHarnessError.spawnFailed(errno) }
    guard descriptor > STDERR_FILENO else {
        let replacement = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        let code = errno
        _ = close(descriptor)
        guard replacement >= 0 else { throw MatrixRunnerHarnessError.spawnFailed(code) }
        return replacement
    }
    return descriptor
}

private func withMatrixCStringArray<Result>(
    _ strings: [String],
    body: ([UnsafeMutablePointer<CChar>?]) throws -> Result
) rethrows -> Result {
    var pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    pointers.append(nil)
    return try body(pointers)
}

private func sendMatrixSignal(_ signal: Int32, to processIdentifier: Int32) -> Int32 {
    #if canImport(Darwin)
        Darwin.kill(processIdentifier, signal)
    #elseif canImport(Glibc)
        Glibc.kill(processIdentifier, signal)
    #else
        -1
    #endif
}

private func matrixSignalName(_ signal: Int32) -> String {
    switch signal {
    case SIGHUP:
        "HUP"
    case SIGINT:
        "INT"
    case SIGTERM:
        "TERM"
    default:
        "UNKNOWN"
    }
}

private func readMatrixKillRecords(from directory: URL) throws -> [MatrixKillRecord] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).map { record in
        let fields = try String(contentsOf: record, encoding: .utf8)
            .split(whereSeparator: \Character.isWhitespace)
        #expect(fields.count == 4)
        let parentField = try #require(fields.first)
        let signalField = try #require(fields.dropFirst().first)
        let targetField = try #require(fields.dropFirst(2).first)
        let statusField = try #require(fields.last)
        let parent = try #require(Int32(parentField))
        let target = try #require(Int32(targetField))
        let status = try #require(Int32(statusField))
        return MatrixKillRecord(
            parent: parent,
            signal: String(signalField),
            target: target,
            status: status
        )
    }
}

private func expectMatrixOwnedJobSignalEvidence(
    _ xtrace: String,
    parent: Int32,
    edge: MatrixPostSpawnFailureEdge,
    expectedSignal: String,
    expectedTarget: Int32
) {
    #expect(
        matrixOwnedJobSignalEvidenceIsAuthenticated(
            xtrace,
            parent: parent,
            edge: edge,
            expectedSignal: expectedSignal,
            expectedTarget: expectedTarget
        )
    )
}

private func matrixOwnedJobSignalEvidenceIsAuthenticated(
    _ xtrace: String,
    parent: Int32,
    edge: MatrixPostSpawnFailureEdge,
    expectedSignal: String,
    expectedTarget: Int32
) -> Bool {
    let entries = matrixTraceEntries(xtrace).filter { $0.owner == parent }
    let invocationPrefix = "signal_owned_job_handle \(edge.rawValue) \(expectedSignal) "
    let invocations = entries.enumerated().filter { _, entry in
        entry.command.hasPrefix(invocationPrefix)
    }
    guard invocations.count == 1 else { return false }
    let invocationIndex = invocations[0].offset
    let fields = invocations[0].element.command.split(whereSeparator: \Character.isWhitespace)
    guard fields.count == 5,
        fields[3].first == "%",
        fields[3].dropFirst().allSatisfy({ $0.isNumber }),
        fields[4] == Substring(String(expectedTarget))
    else { return false }
    let jobSpec = String(fields[3])
    let resolution = "jobs -x test \(jobSpec) = \(expectedTarget)"
    let resolvedComparison = "test \(expectedTarget) = \(expectedTarget)"
    let builtinSignal = "builtin kill -s \(expectedSignal) -- \(jobSpec)"
    let waitCommand = "wait \(expectedTarget)"
    guard entries.filter({ $0.command == waitCommand }).count == 1,
        let waitIndex = entries.firstIndex(where: { $0.command == waitCommand })
    else { return false }
    guard invocationIndex < waitIndex else { return false }
    let signalEntries = entries[invocationIndex..<waitIndex]
    guard
        signalEntries.contains(where: {
            $0.function == "owned_job_handle_is_active" && $0.command == resolution
        }),
        signalEntries.contains(where: {
            $0.function == "owned_job_handle_is_active" && $0.command == resolvedComparison
        }),
        signalEntries.contains(where: {
            $0.function == "signal_owned_job_handle" && $0.command == builtinSignal
        })
    else { return false }
    let entriesAfterWait = entries[entries.index(after: waitIndex)...]
    return !entriesAfterWait.contains(where: {
        $0.command.contains(" \(expectedTarget)")
            && ($0.command.contains("kill -s") || $0.command.contains("signal_owned_job"))
    })
}

private func expectMatrixWaitAuthority(
    _ xtrace: String,
    child: Int32
) {
    let commands = matrixTraceCommands(xtrace)
    let waitCommand = "wait \(child)"
    #expect(commands.filter { $0 == waitCommand }.count == 1)
    guard let waitIndex = commands.firstIndex(of: waitCommand) else { return }
    let commandsAfterWait = commands[commands.index(after: waitIndex)...]
    #expect(
        !commandsAfterWait.contains { command in
            let fields = command.split(whereSeparator: \Character.isWhitespace)
            let numericSignal =
                fields.count == 5
                && fields[0] == "env" && fields[1] == "kill"
                && fields[2] == "-s" && fields[4] == Substring(String(child))
            let ownedJobSignal =
                fields.count == 5
                && fields[0] == "signal_owned_job_handle"
                && fields[4] == Substring(String(child))
            return numericSignal || ownedJobSignal
        }
    )
}

private func matrixOwnedJobSignals(
    _ xtrace: String,
    parent: Int32,
    edge: MatrixPostSpawnFailureEdge,
    child: Int32
) -> [MatrixOwnedJobSignal] {
    matrixTraceEntries(xtrace).filter { $0.owner == parent }.compactMap { entry in
        let fields = entry.command.split(whereSeparator: \Character.isWhitespace)
        guard fields.count == 5,
            fields[0] == "signal_owned_job_handle",
            fields[1] == Substring(edge.rawValue),
            fields[2].allSatisfy({ $0.isUppercase }),
            fields[3].first == "%",
            fields[3].dropFirst().allSatisfy({ $0.isNumber }),
            fields[4] == Substring(String(child))
        else { return nil }
        return MatrixOwnedJobSignal(signal: String(fields[2]), jobSpec: String(fields[3]))
    }
}

private func matrixAssignedProcessIdentifier(
    _ xtrace: String,
    owner: Int32,
    variable: String
) -> Int32? {
    matrixProcessAssignment(xtrace, variable: variable, owner: owner)?.processIdentifier
}

private func matrixProcessAssignment(
    _ xtrace: String,
    variable: String,
    owner expectedOwner: Int32? = nil
) -> MatrixProcessAssignment? {
    let prefix = "\(variable)="
    return matrixTraceEntries(xtrace).lazy.compactMap { entry in
        guard expectedOwner == nil || entry.owner == expectedOwner else { return nil }
        guard entry.command.hasPrefix(prefix) else { return nil }
        guard let processIdentifier = Int32(entry.command.dropFirst(prefix.count)) else {
            return nil
        }
        return MatrixProcessAssignment(
            owner: entry.owner,
            processIdentifier: processIdentifier
        )
    }.first
}

private func matrixTraceCommands(_ xtrace: String) -> [String] {
    matrixTraceEntries(xtrace).map(\.command)
}

private struct MatrixTraceEntry {
    let owner: Int32
    let function: String
    let command: String
}

private func matrixTraceEntries(_ xtrace: String) -> [MatrixTraceEntry] {
    let marker = "TRACE:"
    return xtrace.split(separator: "\n").compactMap { line -> MatrixTraceEntry? in
        guard let markerRange = line.range(of: marker) else { return nil }
        let prefix = line[..<markerRange.lowerBound]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0 == "+" }) else { return nil }
        let payload = line[markerRange.upperBound...]
        guard let ownerEnd = payload.firstIndex(of: ":"),
            let owner = Int32(payload[..<ownerEnd])
        else { return nil }
        let functionAndCommand = payload[payload.index(after: ownerEnd)...]
        guard let functionEnd = functionAndCommand.range(of: ": ") else { return nil }
        return MatrixTraceEntry(
            owner: owner,
            function: String(functionAndCommand[..<functionEnd.lowerBound]),
            command: String(functionAndCommand[functionEnd.upperBound...])
        )
    }
}

private func waitForMatrixRunnerExit(_ running: RunningMatrixRunner) throws {
    try running.owner.waitForExit(timeout: .seconds(10))
}

private func finishMatrixRunner(_ running: RunningMatrixRunner) throws -> ScriptReply {
    let xtrace = (try? String(contentsOf: running.xtraceURL, encoding: .utf8)) ?? ""
    return ScriptReply(
        standardOutput: try String(contentsOf: running.standardOutputURL, encoding: .utf8),
        standardError: (try? String(contentsOf: running.standardErrorURL, encoding: .utf8)) ?? "",
        trace: xtrace,
        status: try running.owner.exitStatus()
    )
}

private let matrixXtraceDescriptor: Int32 = STDERR_FILENO + 1

private func terminateMatrixRunner(
    _ running: RunningMatrixRunner,
    recoveryToken: String
) {
    guard running.owner.stopAndReap() else {
        Issue.record("matrix runner cleanup exceeded its authenticated ownership boundary")
        return
    }
    #expect(
        matrixRecoveryCandidates(recoveryToken: recoveryToken).allSatisfy {
            $0.processIdentifier == running.owner.processIdentifier
        }
    )
}

private struct MatrixRecoveryCandidate {
    let processIdentifier: Int32
    let processGroupIdentifier: Int32
}

private func matrixRecoveryCandidates(recoveryToken: String) -> [MatrixRecoveryCandidate] {
    matrixProcessIdentifiers(withExactArgument: recoveryToken).compactMap { processIdentifier in
        let processGroupIdentifier = getpgid(processIdentifier)
        guard processGroupIdentifier > 0 else { return nil }
        return MatrixRecoveryCandidate(
            processIdentifier: processIdentifier,
            processGroupIdentifier: processGroupIdentifier
        )
    }
}

private func matrixProcessIdentifiers(withExactArgument argument: String) -> [Int32] {
    #if os(Linux)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc")
        else { return [] }
        return entries.compactMap(Int32.init).filter {
            matrixProcessHasExactArgument($0, argument)
        }
    #elseif canImport(Darwin)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", argument]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let listing = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return listing.split(whereSeparator: \Character.isWhitespace).compactMap(Int32.init).filter
        {
            matrixProcessHasExactArgument($0, argument)
        }
    #else
        return []
    #endif
}

private func matrixProcessHasExactArgument(
    _ processIdentifier: Int32,
    _ argument: String
) -> Bool {
    #if os(Linux)
        guard
            let data = FileManager.default.contents(
                atPath: "/proc/\(processIdentifier)/cmdline"
            )
        else { return false }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .contains(Substring(argument))
    #elseif canImport(Darwin)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-p", String(processIdentifier), "-o", "args="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let command = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return command.split(whereSeparator: \Character.isWhitespace)
            .contains(Substring(argument))
    #else
        return false
    #endif
}

private func expectPreservedSignaledMatrixLaneRoot(
    in temporaryRoot: URL,
    payloadStarted: Bool
) throws {
    let laneRoots = try matrixLaneRoots(in: temporaryRoot)
    #expect(laneRoots.count == 1)
    let laneRoot = try #require(laneRoots.first)
    #expect(laneRoot.lastPathComponent.hasPrefix("libtmux-matrix-\(requiredTags[0])."))
    let attributes = try FileManager.default.attributesOfItem(atPath: laneRoot.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue == 0o700)

    var expectedContents = Set(["config", "relay-ownership", "run", "tmp"])
    if payloadStarted {
        expectedContents.insert("lane-artifact")
    }
    let actualContents = Set(try FileManager.default.contentsOfDirectory(atPath: laneRoot.path))
    #expect(actualContents == expectedContents)
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: laneRoot.appendingPathComponent("tmp").path
        ).isEmpty
    )
}

private func matrixLaneRoots(in temporaryRoot: URL) throws -> [URL] {
    let entries = try FileManager.default.contentsOfDirectory(
        at: temporaryRoot,
        includingPropertiesForKeys: [.isDirectoryKey]
    )
    let directLaneRoots = entries.filter {
        $0.lastPathComponent.hasPrefix("libtmux-matrix-")
    }
    if !directLaneRoots.isEmpty {
        return directLaneRoots
    }

    let parents = try entries.filter { entry in
        guard entry.lastPathComponent.hasPrefix("l.") else { return false }
        return try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }
    guard parents.count <= 1 else {
        throw TmuxMatrixError.invalidEvidence("multiple matrix parents")
    }
    guard let parent = parents.first else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: [.isDirectoryKey]
    ).filter { $0.lastPathComponent.hasPrefix("libtmux-matrix-") }
}

private func expectPreservedMatrixLaneRoots(
    in temporaryRoot: URL,
    additionalArtifacts: Set<String> = []
) throws {
    let laneRoots = try matrixLaneRoots(in: temporaryRoot)
    #expect(laneRoots.count == requiredTags.count)

    for tag in requiredTags {
        let prefix = "libtmux-matrix-\(tag)."
        let matchingRoots = laneRoots.filter { $0.lastPathComponent.hasPrefix(prefix) }
        #expect(matchingRoots.count == 1)
        let laneRoot = try #require(matchingRoots.first)
        let resourceValues = try laneRoot.resourceValues(forKeys: [.isDirectoryKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: laneRoot.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        let artifact = laneRoot.appendingPathComponent("lane-artifact")
        let expectedContents = Set(["config", "lane-artifact", "run", "tmp"])
            .union(additionalArtifacts)
        let actualContents = Set(
            try FileManager.default.contentsOfDirectory(atPath: laneRoot.path)
        )

        #expect(resourceValues.isDirectory == true)
        #expect(permissions.intValue == 0o700)
        #expect(actualContents == expectedContents)
        #expect(try String(contentsOf: artifact, encoding: .utf8) == "\(tag)\n")
    }
}

private func waitForProcessesToExit(_ processIdentifiers: [Int32]) {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline,
        processIdentifiers.contains(where: testProcessIsRunning)
    {
        Thread.sleep(forTimeInterval: 0.02)
    }
}

private func retireMatrixCaptureFailureProcesses(
    _ processIdentifiers: [Int32],
    decoyToken: String
) {
    for processIdentifier in processIdentifiers where testProcessIsRunning(processIdentifier) {
        guard processIdentifier > 1,
            getpgid(processIdentifier) == processIdentifier,
            matrixProcessHasExactArgument(processIdentifier, decoyToken)
        else {
            Issue.record("capture-failure test could not authenticate its decoy")
            continue
        }
        _ = sendMatrixSignal(SIGKILL, to: -processIdentifier)
    }
    waitForProcessesToExit(processIdentifiers)
}

private enum FailedMatrixLaunchObservation {
    case running
    case terminal
    case unavailable
}

private func stopAndReapFailedMatrixLaunchForTest(_ processIdentifier: Int32) {
    var observation = observeFailedMatrixLaunchForTest(processIdentifier)
    if observation == .running {
        _ = sendMatrixSignal(SIGTERM, to: processIdentifier)
    }

    let termDeadline = ContinuousClock.now + .seconds(2)
    while observation == .running, ContinuousClock.now < termDeadline {
        Thread.sleep(forTimeInterval: 0.02)
        observation = observeFailedMatrixLaunchForTest(processIdentifier)
    }
    if observation == .running {
        _ = sendMatrixSignal(SIGKILL, to: processIdentifier)
        repeat {
            Thread.sleep(forTimeInterval: 0.02)
            observation = observeFailedMatrixLaunchForTest(processIdentifier)
        } while observation == .running
    }
    guard observation == .terminal else { return }

    var status: Int32 = 0
    var result: pid_t
    repeat {
        errno = 0
        result = waitpid(processIdentifier, &status, 0)
    } while result < 0 && errno == EINTR
}

private func observeFailedMatrixLaunchForTest(
    _ processIdentifier: Int32
) -> FailedMatrixLaunchObservation {
    var information = siginfo_t()
    var result: Int32
    repeat {
        errno = 0
        result = waitid(
            P_PID,
            id_t(processIdentifier),
            &information,
            WEXITED | WNOHANG | WNOWAIT
        )
    } while result < 0 && errno == EINTR
    guard result == 0 else { return .unavailable }
    return matrixSignalInfoProcessIdentifier(information) == processIdentifier
        ? .terminal : .running
}

private func testProcessIsRunning(_ processIdentifier: Int32) -> Bool {
    #if canImport(Darwin)
        Darwin.kill(processIdentifier, 0) == 0
    #elseif canImport(Glibc)
        Glibc.kill(processIdentifier, 0) == 0
    #else
        false
    #endif
}

private func runBuilder(
    source: URL,
    output: URL,
    environment: [String: String] = [:]
) throws -> ScriptReply {
    try runProcess(
        "/bin/bash",
        [matrixBuildScriptURL.path, "--source", source.path, "--output", output.path],
        environment: environment
    )
}

private func runProcess(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String] = [:],
    replacingEnvironment: Bool = false
) throws -> ScriptReply {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    var childEnvironment = replacingEnvironment ? [:] : ProcessInfo.processInfo.environment
    childEnvironment.merge(environment) { _, replacement in replacement }
    process.environment = childEnvironment
    try process.run()
    process.waitUntilExit()

    let error = String(
        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )

    return ScriptReply(
        standardOutput: String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ),
        standardError: error,
        trace: error,
        status: process.terminationStatus
    )
}

private func requireSuccess(_ reply: ScriptReply) throws {
    guard reply.status == 0 else {
        throw TmuxMatrixError.invalidEvidence(reply.standardError)
    }
}

private let laneDeclarationURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/tmux-matrix.json")

private let matrixBuildScriptURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Scripts/build-tmux-matrix.sh")

private let matrixRunnerURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Scripts/run-tmux-matrix.sh")

private let testSpikesURL = matrixRunnerURL.deletingLastPathComponent()
    .appendingPathComponent("test-spikes.sh")

private let pythonReplyOracleURL =
    matrixRunnerURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("docs/superpowers/spikes/evidence/transport/python-reply-oracle.json")
