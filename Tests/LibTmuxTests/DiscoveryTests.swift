import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("finding servers", .timeLimit(.minutes(1)))
struct DiscoveryTests {
    @Test("a running server is found in the directory its socket is in")
    func runningServerIsFound() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(path) = server.endpoint else {
                Issue.record("the fixture addresses by path")
                return
            }
            let directory = (path as NSString).deletingLastPathComponent
            let found = await TmuxServers.discover(
                in: [directory],
                tmuxExecutable: tmuxExecutablePath()
            )
            #expect(found.map(\.socketPath) == [path])
            #expect(found.first?.sessionCount == 1)
            #expect(found.first?.processID != nil)
        }
    }

    @Test("a socket left behind by a server that exited is not reported")
    func staleSocketIsNotAServer() async throws {
        let directory = "/tmp/libtmux-swift-test/stale-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: directory) }
        // tmux leaves the file behind when it exits, so a listing of the
        // directory is a listing of sockets rather than of servers.
        FileManager.default.createFile(atPath: "\(directory)/dead", contents: Data())

        let found = await TmuxServers.discover(
            in: [directory],
            tmuxExecutable: tmuxExecutablePath()
        )
        #expect(found.isEmpty)
    }

    @Test("a directory that is not there is not an error")
    func missingDirectoryIsEmpty() async {
        let found = await TmuxServers.discover(
            in: ["/tmp/libtmux-swift-test/definitely-not-here"],
            tmuxExecutable: tmuxExecutablePath()
        )
        #expect(found.isEmpty)
    }

    @Test("TMUX_TMPDIR is where tmux looks, and so is this")
    func defaultDirectoriesFollowTmux() {
        #expect(
            TmuxServers.defaultDirectories(environment: ["TMUX_TMPDIR": "/somewhere"])
                == ["/somewhere"]
        )
        // tmux builds the fallback from the real user id rather than the name.
        let fallback = TmuxServers.defaultDirectories(environment: [:])
        #expect(fallback == ["/tmp/tmux-\(getuid())"])
    }
}
