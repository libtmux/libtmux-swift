import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("capabilities and bounded reads", .hangLimit)
struct CapabilityAndCaptureTests {
    @Test("capabilities answer for the running release, and the gates agree")
    func capabilitiesMatchTheRunningRelease() async throws {
        try await withTmuxServer { server in
            let version = try await server.version()
            let capabilities = try await server.capabilities()

            #expect(capabilities.version == version)
            // The same boundaries the layout gates use, stated once.
            #expect(
                capabilities.mirroredLayoutPresets
                    == (version >= TmuxVersion(major: 3, minor: 5)))
            #expect(
                capabilities.jsonWindowLayout
                    == (version >= TmuxVersion(major: 3, minor: 8)))

            // A mirrored preset is exactly what the capability predicts.
            let window = try #require(try await server.windows().first)
            _ = try await server.splitWindow(window)
            let mirrored = WindowLayout.custom("main-vertical-mirrored")
            if capabilities.mirroredLayoutPresets {
                try await server.selectLayout(window, mirrored)
            } else {
                await #expect(throws: TmuxError.self) {
                    try await server.selectLayout(window, mirrored)
                }
            }
        }
    }

    @Test("a capture keeps styling only when asked")
    func captureKeepsStylingOnlyWhenAsked() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "styled")
            let window = try await server.newWindow(in: session).window
            let pane = try await server.splitWindow(
                window,
                running: ["sh", "-c", "printf '\\033[31mRED\\033[0m\\n'; sleep 30"]
            )

            let arrived = try await waitUntil {
                try await server.capture(pane).contains { $0.contains("RED") }
            }
            #expect(arrived)

            let plain = try await server.capture(pane, maximumLines: 50)
            let styled = try await server.capture(
                pane, maximumLines: 50, includingAttributes: true)

            // tmux hands back characters by default and what a terminal would
            // draw when asked, which is the difference a caller is choosing.
            #expect(!plain.lines.contains { $0.contains("\u{1B}[") })
            #expect(styled.lines.contains { $0.contains("\u{1B}[") })
            #expect(styled.lines.contains { $0.contains("RED") })
        }
    }

    @Test("a caller's byte ceiling is the one enforced")
    func captureHonorsTheCallersByteCeiling() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "bytes")
            let window = try await server.newWindow(in: session).window
            let pane = try await server.splitWindow(
                window,
                running: [
                    "sh", "-c",
                    "for i in $(seq 1 200); do echo AAAAAAAAAAAAAAAAAAAA; done; sleep 30",
                ]
            )
            let filled = try await waitUntil {
                try await server.capture(pane).contains { $0.contains("AAAA") }
            }
            #expect(filled)

            // The default holds this comfortably; 64 bytes cannot.
            _ = try await server.capture(pane, includingHistory: true, maximumLines: 500)
            await #expect(throws: TmuxError.outputLimitExceeded(perStreamBytes: 64)) {
                _ = try await server.capture(
                    pane, includingHistory: true, maximumLines: 500, maximumBytes: 64)
            }
        }
    }

    @Test("a signalled client is not an exit status")
    func signalledClientIsNotAnExitStatus() {
        #expect(
            TmuxReply(standardOutput: [], standardError: [], exitCode: 0).termination
                == .exited(status: 0))
        #expect(
            TmuxReply(standardOutput: [], standardError: [], exitCode: 15).termination
                == .exited(status: 15))
        // The sign is what told these apart before, which a reader had to know.
        #expect(
            TmuxReply(standardOutput: [], standardError: [], exitCode: -15).termination
                == .signalled(signal: 15))
    }

    @Test("a daemon's start time has a date view of the same instant")
    func daemonStartDateMatchesItsIntegerSeconds() async throws {
        try await withTmuxServer { server in
            let incarnation = try await server.incarnation()

            #expect(
                incarnation.startDate
                    == Date(timeIntervalSince1970: TimeInterval(incarnation.startedAt)))
            #expect(abs(incarnation.startDate.timeIntervalSinceNow) < 600)
        }
    }
}
