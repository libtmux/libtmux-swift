import Foundation
import Testing

@testable import TmuxFixture

/// Which tmux a run uses: `LIBTMUX_TEST_TMUX`, then `LIBTMUX_TMUX_BIN`, then `PATH`,
/// then the install locations.
@Suite("tmux selection", .timeLimit(.minutes(1)))
struct TmuxSelectionTests {
    @Test("a tmux on PATH is used over an installed one")
    func pathBeatsInstalledLocations() throws {
        try withExecutables(["bin/tmux", "installed/tmux"]) { root in
            let chosen = tmuxExecutablePath(
                resolving: ["PATH": root.appendingPathComponent("bin").path],
                installedLocations: [root.appendingPathComponent("installed/tmux").path])

            #expect(chosen == root.appendingPathComponent("bin/tmux").path)
        }
    }

    @Test("the first PATH entry holding an executable tmux wins")
    func theFirstExecutableOnPathWins() throws {
        try withExecutables(["empty/other", "first/tmux", "second/tmux"]) { root in
            let notExecutable = root.appendingPathComponent("plain")
            try FileManager.default.createDirectory(
                at: notExecutable, withIntermediateDirectories: false)
            try Data().write(to: notExecutable.appendingPathComponent("tmux"))
            let path = ["empty", "plain", "first", "second"]
                .map { root.appendingPathComponent($0).path }.joined(separator: ":")

            let chosen = tmuxExecutablePath(resolving: ["PATH": path], installedLocations: [])

            #expect(chosen == root.appendingPathComponent("first/tmux").path)
        }
    }

    @Test("LIBTMUX_TEST_TMUX beats LIBTMUX_TMUX_BIN and PATH, and is used untrimmed")
    func testVariableBeatsLegacyAndPath() throws {
        try withExecutables(["bin/tmux"]) { root in
            let bin = root.appendingPathComponent("bin").path
            let selected = [
                "LIBTMUX_TEST_TMUX": "/opt/tmux-3.8/bin/tmux",
                "LIBTMUX_TMUX_BIN": "/opt/tmux-3.3a/bin/tmux",
                "PATH": bin,
            ]
            let padded = [
                "LIBTMUX_TEST_TMUX": " /opt/tmux-3.8/bin/tmux ",
                "LIBTMUX_TMUX_BIN": "/opt/tmux-3.3a/bin/tmux",
                "PATH": bin,
            ]

            #expect(tmuxExecutablePath(resolving: selected) == "/opt/tmux-3.8/bin/tmux")
            #expect(tmuxExecutablePath(resolving: padded) == " /opt/tmux-3.8/bin/tmux ")
        }
    }

    @Test("a bare LIBTMUX_TEST_TMUX is searched for on PATH, as the library does")
    func aBareTestVariableIsSearchedOnPath() throws {
        try withExecutables(["bin/tmux-3.8", "bin/tmux-3.3a"]) { root in
            let environment = [
                "LIBTMUX_TEST_TMUX": "tmux-3.8",
                "LIBTMUX_TMUX_BIN": "tmux-3.3a",
                "PATH": root.appendingPathComponent("bin").path,
            ]

            #expect(
                tmuxExecutablePath(resolving: environment)
                    == root.appendingPathComponent("bin/tmux-3.8").path)
        }
    }

    @Test("a LIBTMUX_TEST_TMUX that resolves to nothing is not swapped for another tmux")
    func aMissedTestVariableIsKept() throws {
        try withExecutables(["bin/tmux", "installed/tmux"]) { root in
            let environment = [
                "LIBTMUX_TEST_TMUX": "tmux-absent",
                "LIBTMUX_TMUX_BIN": root.appendingPathComponent("bin/tmux").path,
                "PATH": root.appendingPathComponent("bin").path,
            ]

            let chosen = tmuxExecutablePath(
                resolving: environment,
                installedLocations: [root.appendingPathComponent("installed/tmux").path])

            #expect(chosen == "tmux-absent")
        }
    }

    @Test(
        "an empty or whitespace-only LIBTMUX_TEST_TMUX falls back to LIBTMUX_TMUX_BIN, then PATH",
        arguments: ["", " ", "   \t\n "]
    )
    func aBlankTestVariableIsUnset(_ blank: String) throws {
        try withExecutables(["bin/tmux"]) { root in
            let bin = root.appendingPathComponent("bin").path
            let withLegacy = [
                "LIBTMUX_TEST_TMUX": blank,
                "LIBTMUX_TMUX_BIN": "/opt/tmux-3.3a/bin/tmux",
                "PATH": bin,
            ]
            let withPathOnly = [
                "LIBTMUX_TEST_TMUX": blank,
                "PATH": bin,
            ]

            #expect(tmuxExecutablePath(resolving: withLegacy) == "/opt/tmux-3.3a/bin/tmux")
            #expect(
                tmuxExecutablePath(resolving: withPathOnly)
                    == root.appendingPathComponent("bin/tmux").path)
        }
    }

    @Test("LIBTMUX_TMUX_BIN beats PATH as a fallback and is used untrimmed")
    func theLegacyVariableBeatsPath() throws {
        try withExecutables(["bin/tmux"]) { root in
            let bin = root.appendingPathComponent("bin").path
            let environment = [
                "LIBTMUX_TMUX_BIN": "/opt/tmux-3.3a/bin/tmux",
                "PATH": bin,
            ]
            let padded = [
                "LIBTMUX_TMUX_BIN": " /opt/tmux-3.3a/bin/tmux ",
                "PATH": bin,
            ]

            #expect(tmuxExecutablePath(resolving: environment) == "/opt/tmux-3.3a/bin/tmux")
            #expect(tmuxExecutablePath(resolving: padded) == " /opt/tmux-3.3a/bin/tmux ")
        }
    }

    @Test("a bare LIBTMUX_TMUX_BIN is searched for on PATH, as the library does")
    func aBareLegacyVariableIsSearchedOnPath() throws {
        try withExecutables(["bin/tmux-3.3a"]) { root in
            let environment = [
                "LIBTMUX_TMUX_BIN": "tmux-3.3a",
                "PATH": root.appendingPathComponent("bin").path,
            ]

            #expect(
                tmuxExecutablePath(resolving: environment)
                    == root.appendingPathComponent("bin/tmux-3.3a").path)
        }
    }

    @Test("a LIBTMUX_TMUX_BIN that resolves to nothing is not swapped for another tmux")
    func aMissedLegacyVariableIsKept() throws {
        try withExecutables(["bin/tmux", "installed/tmux"]) { root in
            let environment = [
                "LIBTMUX_TMUX_BIN": "tmux-absent",
                "PATH": root.appendingPathComponent("bin").path,
            ]

            let chosen = tmuxExecutablePath(
                resolving: environment,
                installedLocations: [root.appendingPathComponent("installed/tmux").path])

            #expect(chosen == "tmux-absent")
        }
    }

    @Test(
        "an empty or whitespace-only LIBTMUX_TMUX_BIN counts as unset",
        arguments: ["", " ", "\t\n"]
    )
    func aBlankLegacyVariableIsUnset(_ blank: String) throws {
        try withExecutables(["bin/tmux"]) { root in
            let environment = [
                "LIBTMUX_TMUX_BIN": blank, "PATH": root.appendingPathComponent("bin").path,
            ]

            #expect(
                tmuxExecutablePath(resolving: environment)
                    == root.appendingPathComponent("bin/tmux").path)
        }
    }

    @Test("with no tmux on PATH, the first installed location that exists is used")
    func anInstalledLocationIsTheFallback() throws {
        try withExecutables(["bin/other", "second/tmux", "third/tmux"]) { root in
            let locations = ["absent/tmux", "second/tmux", "third/tmux"]
                .map { root.appendingPathComponent($0).path }

            let chosen = tmuxExecutablePath(
                resolving: ["PATH": root.appendingPathComponent("bin").path],
                installedLocations: locations)

            #expect(chosen == locations[1])
        }
    }

    @Test("with no tmux anywhere, /usr/bin/tmux is named so the failure names a path")
    func nothingFoundNamesUsrBin() {
        #expect(
            tmuxExecutablePath(resolving: ["PATH": "/nonexistent"], installedLocations: [])
                == "/usr/bin/tmux")
    }
}

/// Runs `body` with a directory holding an executable file at each relative path.
private func withExecutables(
    _ paths: [String], _ body: (URL) throws -> Void
) throws {
    let root = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directory = root.appendingPathComponent("selection-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }

    for path in paths {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    try body(directory)
}
