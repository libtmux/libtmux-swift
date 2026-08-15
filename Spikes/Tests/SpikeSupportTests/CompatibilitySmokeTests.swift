import Foundation
import Testing

@testable import SpikeSupport

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@Suite(
    "authenticated tmux compatibility",
    .serialized,
    .enabled(if: hasMatrixLaneEnvironment, "requires an authenticated matrix lane")
)
struct CompatibilitySmokeTests {
    @Test("pane fixture survives delayed 3.2a setup")
    func paneFixtureSurvivesDelayed3_2aSetup() throws {
        let lane = try currentLane()
        guard lane.rawTag == "3.2a" else {
            return
        }

        let socket = try privateSocket(named: "lifetime")
        let server = try ForegroundTmuxServer(
            lane: lane,
            socket: socket,
            initialArguments: ["new-session", "-d", "-s", "compat"] + paneFixtureCommand
        )
        defer { server.stop() }

        Thread.sleep(forTimeInterval: 31)
        let reply = try tmux(
            lane,
            socket: socket,
            arguments: ["display-message", "-p", "-t", "compat", "#{pane_id}"]
        )
        try requireSuccess(reply)
        #expect(reply.standardOutput.hasPrefix("%"))
    }

    @Test("version discovery preserves the lane suffix")
    func versionDiscoveryPreservesLaneSuffix() throws {
        let lane = try currentLane()
        let reply = try run(lane.executablePath, ["-V"])
        #expect(reply.status == 0)
        #expect(reply.standardError.isEmpty)

        let discovered = try TmuxCompatibility.version(fromReportedVersion: reply.standardOutput)
        #expect(discovered.rawTag == lane.rawTag)
        #expect(discovered.numericVersion == lane.numericVersion)
        #expect(discovered.suffix == lane.suffix)
    }

    @Test("lane-sensitive pane formats identify the running tmux")
    func laneSensitiveFormatsIdentifyRunningTmux() throws {
        let lane = try currentLane()
        let socket = try privateSocket(named: "formats")
        let server = try ForegroundTmuxServer(
            lane: lane,
            socket: socket,
            initialArguments: ["new-session", "-d", "-s", "compat"] + paneFixtureCommand
        )
        defer { server.stop() }

        let fields = TmuxCompatibility.paneFormatFields(for: lane.numericVersion)
        let format = fields.map { "#{\($0)}" }.joined(separator: "␞")
        let reply = try tmux(
            lane,
            socket: socket,
            arguments: ["list-panes", "-t", "compat", "-F", format]
        )
        try requireSuccess(reply)

        let values = reply.standardOutput
            .trimmingCharacters(in: CharacterSet.newlines)
            .split(separator: "␞", omittingEmptySubsequences: false)
            .map(String.init)
        #expect(values.count == fields.count)
        let versionIndex = try #require(fields.firstIndex(of: "version"))
        #expect(values[versionIndex] == lane.rawTag)

        #expect(fields.contains("pane_dead_signal") == (lane.numericVersion >= version3_3))
        #expect(fields.contains("pane_flags") == (lane.numericVersion >= version3_7))
    }

    @Test("break-pane applies only the raw 3.7 crash workaround")
    func breakPaneAppliesOnlyRaw3_7Workaround() throws {
        let lane = try currentLane()
        let socket = try privateSocket(named: "break")
        let server = try ForegroundTmuxServer(
            lane: lane,
            socket: socket,
            initialArguments: ["new-session", "-d", "-s", "compat", "-n", "base"]
                + paneFixtureCommand
        )
        defer { server.stop() }
        let split = try tmux(
            lane,
            socket: socket,
            arguments: [
                "split-window", "-d", "-P", "-F", "#{pane_id}", "-t", "compat:base",
            ] + paneFixtureCommand
        )
        try requireSuccess(split)
        let paneID = split.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        let workaroundName = TmuxCompatibility.breakPaneNameArgument(
            rawTag: lane.rawTag,
            requestedName: nil
        )
        #expect((workaroundName != nil) == (lane.rawTag == "3.7"))

        var arguments = ["break-pane", "-P", "-F", "#{window_id}", "-d"]
        if let workaroundName {
            arguments.append(contentsOf: ["-n", workaroundName])
        }
        arguments.append(contentsOf: ["-s", paneID])

        let broken = try tmux(lane, socket: socket, arguments: arguments)
        try requireSuccess(broken)
        let windowID = broken.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!windowID.isEmpty)

        if lane.rawTag == "3.7" {
            #expect(workaroundName == "libtmux")
        } else if lane.rawTag == "3.7a" || lane.rawTag == "3.7b" {
            let naturalName = try waitForWindowName(
                lane,
                socket: socket,
                windowID: windowID,
                expected: "sleep"
            )
            #expect(naturalName == "sleep")
        }
    }
}

private struct SmokeCommandReply: Sendable {
    let standardOutput: String
    let standardError: String
    let status: Int32
}

private enum CompatibilitySmokeError: Error {
    case commandFailed(SmokeCommandReply)
    case missingEnvironment(String)
    case serverStartDeadline
    case windowNameDeadline(String)
}

private final class ForegroundTmuxServer {
    private let lane: TmuxLane
    private let socket: String
    private let process: Process
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private let standardOutputURL: URL
    private let standardErrorURL: URL

    init(lane: TmuxLane, socket: String, initialArguments: [String]) throws {
        self.lane = lane
        self.socket = socket
        let captureDirectory = try commandCaptureDirectory()
        let token = UUID().uuidString
        standardOutputURL = captureDirectory.appendingPathComponent("\(token).server.stdout")
        standardErrorURL = captureDirectory.appendingPathComponent("\(token).server.stderr")
        _ = FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
        standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        standardError = try FileHandle(forWritingTo: standardErrorURL)
        try? FileManager.default.removeItem(atPath: socket)

        process = Process()
        process.executableURL = URL(fileURLWithPath: lane.executablePath)
        process.arguments = ["-D", "-S", socket, "-f", "/dev/null"]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()

        let deadline = ContinuousClock.now + .seconds(3)
        var serverReady = false
        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                stop()
                throw CompatibilitySmokeError.serverStartDeadline
            }
            let readiness = try? run(
                lane.executablePath,
                ["-N", "-S", socket, "-f", "/dev/null", "display-message", "-p", "#{pid}"]
            )
            if readiness?.status == 0,
                readiness?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    == String(process.processIdentifier)
            {
                serverReady = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard process.isRunning, serverReady else {
            stop()
            throw CompatibilitySmokeError.serverStartDeadline
        }
        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                stop()
                throw CompatibilitySmokeError.serverStartDeadline
            }
            let reply = try? tmux(lane, socket: socket, arguments: initialArguments)
            if reply?.status == 0, process.isRunning {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        stop()
        throw CompatibilitySmokeError.serverStartDeadline
    }

    func stop() {
        let paneProcessIdentifiers = paneProcessIdentifiers()
        _ = try? tmux(lane, socket: socket, arguments: ["kill-session", "-t", "compat"])
        terminateOwnedPanes(paneProcessIdentifiers)
        if process.isRunning {
            forceKill(process.processIdentifier)
        }
        process.waitUntilExit()
        try? standardOutput.close()
        try? standardError.close()
        try? FileManager.default.removeItem(atPath: socket)
        try? FileManager.default.removeItem(at: standardOutputURL)
        try? FileManager.default.removeItem(at: standardErrorURL)
    }

    private func paneProcessIdentifiers() -> [Int32] {
        guard
            let reply = try? tmux(
                lane,
                socket: socket,
                arguments: ["list-panes", "-a", "-F", "#{pane_pid}"]
            ),
            reply.status == 0
        else {
            return []
        }

        return reply.standardOutput.split(whereSeparator: \.isNewline).compactMap {
            Int32($0)
        }
    }
}

private func forceKill(_ processIdentifier: Int32) {
    #if canImport(Darwin)
        _ = Darwin.kill(processIdentifier, SIGKILL)
    #elseif canImport(Glibc)
        _ = Glibc.kill(processIdentifier, SIGKILL)
    #endif
}

private func terminateOwnedPanes(_ processIdentifiers: [Int32]) {
    for processIdentifier in processIdentifiers {
        #if canImport(Darwin)
            _ = Darwin.kill(processIdentifier, SIGTERM)
        #elseif canImport(Glibc)
            _ = Glibc.kill(processIdentifier, SIGTERM)
        #endif
    }

    Thread.sleep(forTimeInterval: 0.02)
    for processIdentifier in processIdentifiers where processIsRunning(processIdentifier) {
        forceKill(processIdentifier)
    }
}

private func processIsRunning(_ processIdentifier: Int32) -> Bool {
    #if canImport(Darwin)
        Darwin.kill(processIdentifier, 0) == 0
    #elseif canImport(Glibc)
        Glibc.kill(processIdentifier, 0) == 0
    #else
        false
    #endif
}

private let version3_3 = TmuxNumericVersion(major: 3, minor: 3)
private let version3_7 = TmuxNumericVersion(major: 3, minor: 7)
private let paneFixtureCommand = ["sleep", "3600"]

private var hasMatrixLaneEnvironment: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["LIBTMUX_TMUX_BIN"] != nil
        && environment["LIBTMUX_TMUX_TAG"] != nil
        && environment["LIBTMUX_MATRIX_ROOT"] != nil
        && environment["LIBTMUX_MATRIX_MANIFEST"] != nil
        && environment["LIBTMUX_MATRIX_BINARY_ROOT"] != nil
}

private func currentLane() throws -> TmuxLane {
    let environment = ProcessInfo.processInfo.environment
    let tag = try requiredEnvironment("LIBTMUX_TMUX_TAG", from: environment)
    let manifest = try requiredEnvironment("LIBTMUX_MATRIX_MANIFEST", from: environment)
    let binaryRoot = try requiredEnvironment("LIBTMUX_MATRIX_BINARY_ROOT", from: environment)
    let matrix = try TmuxMatrix.load(
        laneDeclarationAt: smokeLaneDeclarationURL,
        evidenceAt: URL(fileURLWithPath: manifest),
        binariesAt: URL(fileURLWithPath: binaryRoot, isDirectory: true)
    )
    let lane = try #require(matrix.lanes.first { $0.rawTag == tag })
    let executable = try requiredEnvironment("LIBTMUX_TMUX_BIN", from: environment)
    #expect(lane.executablePath == executable)
    return lane
}

private func privateSocket(named purpose: String) throws -> String {
    let environment = ProcessInfo.processInfo.environment
    let root = try requiredEnvironment("LIBTMUX_MATRIX_ROOT", from: environment)
    return URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("\(purpose).sock")
        .path
}

private func requiredEnvironment(
    _ key: String,
    from environment: [String: String]
) throws -> String {
    guard let value = environment[key], !value.isEmpty else {
        throw CompatibilitySmokeError.missingEnvironment(key)
    }
    return value
}

private func tmux(
    _ lane: TmuxLane,
    socket: String,
    arguments: [String]
) throws -> SmokeCommandReply {
    try run(lane.executablePath, ["-S", socket, "-f", "/dev/null"] + arguments)
}

private func run(_ executable: String, _ arguments: [String]) throws -> SmokeCommandReply {
    let process = Process()
    let captureDirectory = try commandCaptureDirectory()
    let token = UUID().uuidString
    let standardOutputURL = captureDirectory.appendingPathComponent("\(token).stdout")
    let standardErrorURL = captureDirectory.appendingPathComponent("\(token).stderr")
    _ = FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: standardOutputURL)
        try? FileManager.default.removeItem(at: standardErrorURL)
    }

    let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
    let standardError = try FileHandle(forWritingTo: standardErrorURL)
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    try standardOutput.close()
    try standardError.close()

    return SmokeCommandReply(
        standardOutput: String(
            decoding: try Data(contentsOf: standardOutputURL),
            as: UTF8.self
        ),
        standardError: String(
            decoding: try Data(contentsOf: standardErrorURL),
            as: UTF8.self
        ),
        status: process.terminationStatus
    )
}

private func commandCaptureDirectory() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    let root = try requiredEnvironment("LIBTMUX_MATRIX_ROOT", from: environment)
    let directory = URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("command-captures", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func requireSuccess(_ reply: SmokeCommandReply) throws {
    guard reply.status == 0, reply.standardError.isEmpty else {
        throw CompatibilitySmokeError.commandFailed(reply)
    }
}

private func waitForWindowName(
    _ lane: TmuxLane,
    socket: String,
    windowID: String,
    expected: String
) throws -> String {
    let deadline = ContinuousClock.now + .seconds(3)
    var lastName = ""

    while ContinuousClock.now < deadline {
        let reply = try tmux(
            lane,
            socket: socket,
            arguments: ["display-message", "-p", "-t", windowID, "#{window_name}"]
        )
        try requireSuccess(reply)
        lastName = reply.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if lastName == expected {
            return lastName
        }
        Thread.sleep(forTimeInterval: 0.02)
    }

    throw CompatibilitySmokeError.windowNameDeadline(lastName)
}

private let smokeLaneDeclarationURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/tmux-matrix.json")
