import Foundation
import Testing
import TmuxFixture

@Suite("fixture root")
struct FixtureRootTests {
    @Test("a root a sweep must never be pointed at is refused")
    func dangerousRootsAreRefused() {
        // The reaper's last act is `rm -rf`, so each of these is a path that
        // must never reach it.
        for path in ["/", "/tmp", "/usr", "relative/path", "", "/tmp/"] {
            #expect(throws: UnsafeReaperRoot.self, "accepted \(path.debugDescription)") {
                _ = try TmuxFixtureRoot(path)
            }
        }
    }

    @Test("a consumer can name its own root")
    func aConsumerCanNameItsOwnRoot() throws {
        let mine = try TmuxFixtureRoot("/tmp/some-other-port-test")

        #expect(mine.url.path == "/tmp/some-other-port-test")
        #expect(TmuxFixtureRoot.package.url.path == "/tmp/libtmux-swift-test")
    }

    @Test("the reaper sweeps only below the root it was given")
    func reaperSweepsOnlyBelowItsRoot() throws {
        let mine = try TmuxFixtureRoot("/tmp/some-other-port-test")

        // Strictly below: a sweep of the root itself would take every other
        // case's socket with it.
        _ = try reaperCommand(root: mine.url.appendingPathComponent("abc"), within: mine)
        #expect(throws: UnsafeReaperRoot.self) {
            _ = try reaperCommand(root: mine.url, within: mine)
        }
        #expect(throws: UnsafeReaperRoot.self) {
            _ = try reaperCommand(root: URL(fileURLWithPath: "/tmp/elsewhere/abc"), within: mine)
        }
    }
}
