import Foundation
import LibTmux
import Testing

@testable import LibTmuxMCP

/// An MCP server is launched by a client that passes no flags, so the
/// environment is the whole configuration surface. Getting it wrong is silent
/// by nature — nobody sees a flag that was not accepted.
@Suite("configuration")
struct ConfigurationTests {
    @Test("with nothing set it serves the default socket at the mutating tier")
    func defaultsAreTheOnesDocumented() {
        let configuration = ServerConfiguration(environment: [:])
        #expect(configuration.socketName == "default")
        #expect(configuration.socketPath == nil)
        #expect(configuration.tmuxExecutable == "tmux")
        #expect(configuration.tier == .mutating)
        #expect(configuration.waitCeiling == .seconds(120))
        #expect(configuration.warnings.isEmpty)
    }

    @Test("a socket path wins over a name, because it names one server")
    func socketPathWins() {
        let configuration = ServerConfiguration(
            environment: ["LIBTMUX_SOCKET": "named", "LIBTMUX_SOCKET_PATH": "/tmp/s"]
        )
        // A name is resolved inside TMUX_TMPDIR and so denotes different
        // servers in different environments; a path denotes one socket.
        #expect(configuration.socketPath == "/tmp/s")
        #expect(configuration.socketName == nil)
    }

    @Test("each safety tier is honoured by name")
    func tiersAreRead() {
        for tier in SafetyTier.allCases {
            let configuration = ServerConfiguration(
                environment: ["LIBTMUX_SAFETY": tier.rawValue]
            )
            #expect(configuration.tier == tier)
            #expect(configuration.warnings.isEmpty)
        }
    }

    @Test("a tier nobody recognises serves reading only, and says so")
    func misspeltTierFallsBackToReading() {
        let configuration = ServerConfiguration(
            environment: ["LIBTMUX_SAFETY": "destructve"]
        )
        // The lowest tier rather than the default: a misspelt value is a
        // configuration nobody checked, and reading is the only assumption
        // safe to make on an operator's behalf.
        #expect(configuration.tier == .readonly)
        #expect(configuration.warnings.count == 1)
        #expect(configuration.warnings.first?.contains("destructve") == true)
    }

    @Test("a wait ceiling past the hard limit is clamped, and says so")
    func ceilingIsClamped() {
        let configuration = ServerConfiguration(
            environment: ["LIBTMUX_MCP_WAIT_MAX_SECONDS": "9999"]
        )
        #expect(
            configuration.waitCeiling
                == .seconds(Int(ServerConfiguration.hardWaitCeiling))
        )
        #expect(configuration.warnings.count == 1)
    }

    @Test("a ceiling that is not a number falls back rather than becoming zero")
    func unreadableCeilingFallsBack() {
        // `Double("soon")` is nil, and treating that as zero would make every
        // wait return immediately — a server that answers instantly and
        // uselessly is worse than one that refuses to start.
        let configuration = ServerConfiguration(
            environment: ["LIBTMUX_MCP_WAIT_MAX_SECONDS": "soon"]
        )
        #expect(configuration.waitCeiling == .seconds(120))
    }

    @Test("a ceiling of zero still leaves a wait long enough to do anything")
    func ceilingHasAFloor() {
        let configuration = ServerConfiguration(
            environment: ["LIBTMUX_MCP_WAIT_MAX_SECONDS": "0"]
        )
        #expect(configuration.waitCeiling >= .seconds(1))
    }

    @Test("what it will address is what it says it is addressing")
    func summaryMatchesTheEndpoint() throws {
        let named = ServerConfiguration(environment: ["LIBTMUX_SOCKET": "work"])
        #expect(named.endpointSummary.contains("work"))
        let path = ServerConfiguration(
            environment: ["LIBTMUX_SOCKET_PATH": "/tmp/libtmux-swift-test/s"]
        )
        #expect(path.endpointSummary.contains("/tmp/libtmux-swift-test/s"))
        // The line the operator reads on stderr should name the thing that
        // would be wrong, which is the endpoint rather than the variable.
        #expect(try path.makeServer().endpoint == .socketPath("/tmp/libtmux-swift-test/s"))
    }
}
