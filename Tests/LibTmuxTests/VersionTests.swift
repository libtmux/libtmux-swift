import Testing
import TmuxFixture

@testable import LibTmux

@Suite("tmux versions")
struct VersionTests {
    @Test(
        "what tmux prints reads back as what it is",
        arguments: [
            ("tmux 3.2a", 3, 2, "a", String?.none),
            ("tmux 3.4", 3, 4, "", String?.none),
            ("tmux 3.7b", 3, 7, "b", String?.none),
            ("3.5", 3, 5, "", String?.none),
            ("tmux 3.4-master", 3, 4, "", String?.some("master")),
            ("tmux 3.2-openbsd", 3, 2, "", String?.some("openbsd")),
            ("tmux next-3.8", 3, 8, "", String?.some("next")),
        ]
    )
    func versionStringsParse(
        _ text: String, _ major: Int, _ minor: Int, _ point: String, _ build: String?
    ) throws {
        let version = try #require(TmuxVersion(parsing: text))
        #expect(version.major == major)
        #expect(version.minor == minor)
        #expect(version.pointRelease == point)
        #expect(version.build == build)
    }

    @Test(
        "something that is not a version is not guessed at",
        arguments: ["", "tmux", "tmux x.y", "tmux 3", "tmux 3.x", "tmux 3.2!"]
    )
    func nonVersionsAreRefused(_ text: String) {
        #expect(TmuxVersion(parsing: text) == nil)
    }

    @Test("a point release sorts after the release it patches")
    func pointReleasesOrder() throws {
        let ordered = [
            TmuxVersion(parsing: "3.2")!,
            TmuxVersion(parsing: "3.2a")!,
            TmuxVersion(parsing: "3.3")!,
            TmuxVersion(parsing: "3.3a")!,
            TmuxVersion(parsing: "3.7")!,
            TmuxVersion(parsing: "3.7a")!,
            TmuxVersion(parsing: "3.7b")!,
            TmuxVersion(parsing: "3.10")!,
        ]
        #expect(ordered == ordered.sorted())
        // The one that matters: 3.7 shipped a break-pane crash, 3.7a reverted
        // it, so these must not compare equal.
        #expect(TmuxVersion(parsing: "3.7")! < TmuxVersion(parsing: "3.7a")!)
        // And a two-digit minor is a number, not text.
        #expect(TmuxVersion(parsing: "3.9")! < TmuxVersion(parsing: "3.10")!)
    }

    @Test("it round-trips through its own description")
    func descriptionRoundTrips() throws {
        for text in ["3.2a", "3.4", "3.7b", "3.4-master", "3.8-next"] {
            let version = try #require(TmuxVersion(parsing: text))
            #expect(TmuxVersion(parsing: version.description) == version)
        }
    }

    @Test("the server reports the tmux it runs")
    func serverReportsItsVersion() async throws {
        try await withTmuxServer { server in
            let version = try await server.version()
            #expect(version.major >= 3)
            // The lane the suite was told to run, when it was told one. CI
            // installs each release into `tmux-<tag>/`, and AGENTS.md spells
            // the variable the same way, so the directory carries a prefix the
            // tag does not: `tmux-3.7b` parses as 3.7b-tmux and matches
            // nothing. A directory that is not a lane — `/usr/local/bin/tmux`
            // gives `local` — still parses to nothing, and skips the check.
            let lane = tmuxExecutablePath()
            if let directory = lane.split(separator: "/").dropLast(2).last,
                let expected = TmuxVersion(
                    parsing: String(
                        directory.hasPrefix("tmux-")
                            ? directory.dropFirst("tmux-".count) : directory
                    )
                )
            {
                #expect(version == expected)
            }
        }
    }
}
