import Foundation

/// The tmux release a daemon or executable reported, kept with the exact token
/// it reported so a fence can ask the daemon for the same string back.
struct ServerVersion: Sendable, Hashable {
    let token: String
    let version: TmuxVersion
}

extension TmuxVersion {
    /// The oldest release ordinary operations accept.
    ///
    /// Compared as a whole release, patch letter included: 3.3 sits below it.
    static let coreMinimum = TmuxVersion(major: 3, minor: 3, pointRelease: "a")

    /// Whether ordinary operations accept this build.
    ///
    /// A snapshot (`next-X.Y`) or release candidate ranks below the release it
    /// names, so a snapshot or candidate of 3.3a is refused and one of a later
    /// release is not. A build suffix tmux has not reported is refused rather
    /// than treated as a release: `openbsd` carries OpenBSD's own numbering,
    /// which says nothing about the tmux release underneath it.
    var isCoreSupported: Bool {
        if let build, !Support.Versions.recognizedBuild(build, pointRelease: pointRelease) {
            return false
        }
        return self >= .coreMinimum
    }
}

/// The tmux versions this library supports. `Support` means tmux version and
/// feature support, not helper code.
enum Support {}

extension Support {
    /// How a daemon or executable is checked, and how a command is held to the
    /// version that check read. Pure functions, so every rule is testable
    /// without a process.
    enum Versions {
        /// Reads the version off a reported token and refuses an unsupported one.
        static func requireCore(_ token: String) throws(TmuxError) -> ServerVersion {
            guard isFormatSafe(token), let version = TmuxVersion(parsing: token) else {
                throw .invocationFailed(
                    reason: "could not read a tmux version from \(token.debugDescription); "
                        + "libtmux requires tmux \(TmuxVersion.coreMinimum) or newer"
                )
            }
            // A report that names no release is not a release below the floor:
            // "needs 3.3a; this server is master" would be false advice.
            if let build = version.build,
                !recognizedBuild(build, pointRelease: version.pointRelease)
            {
                throw .invocationFailed(
                    reason: "tmux reported \(token.debugDescription), which names no release; "
                        + "libtmux requires tmux \(TmuxVersion.coreMinimum) or newer"
                )
            }
            guard version.isCoreSupported else {
                throw .unsupportedTmuxVersion(
                    reported: token,
                    required: "\(TmuxVersion.coreMinimum)",
                    operation: "any command"
                )
            }
            return ServerVersion(token: token, version: version)
        }

        /// The builds tmux has reported: a development snapshot (`next-X.Y`,
        /// never with a patch letter) and a release candidate (`X.Y-rc`,
        /// `X.Y-rcN`). Wrappers have spelled others, such as `X.Y-master`; tmux
        /// has not, and one is refused rather than ranked.
        static func recognizedBuild(_ build: String, pointRelease: String) -> Bool {
            if build == "next" { return pointRelease.isEmpty }
            guard build.hasPrefix("rc") else { return false }
            let number = build.dropFirst(2)
            return number.isEmpty || (number.allSatisfy(\.isNumber) && Int(number) != nil)
        }

        /// A token is embedded in a format condition, so only the characters a
        /// release is spelled with may reach one.
        private static func isFormatSafe(_ token: String) -> Bool {
            !token.isEmpty
                && token.unicodeScalars.allSatisfy {
                    ($0.value < 128)
                        && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
                }
        }

        // MARK: Probe

        /// A command name no tmux knows, unique to one dispatch.
        static func makeMarker() -> String {
            "libtmux-version-"
                + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }

        /// The probe asks the daemon for its version without running a command
        /// that fires hooks.
        ///
        /// `run-shell -C` expands the format and parses the result as a command
        /// after the command that asked has returned, so the parse error is the
        /// answer: `unknown command: <marker><version>`. `run-shell` carries no
        /// after-command hook, and tmux inserts no `command-error` for a command
        /// that has already returned. `display-message` would fire
        /// `after-display-message` in a user's configuration before any refusal.
        static func probeArguments(marker: String) -> [String] {
            ["-N", "run-shell", "-C", "\(marker)-#{version}"]
        }

        enum Probe: Equatable {
            case version(String)
            /// The daemon predates `run-shell -C` (tmux 3.2), so it is older than
            /// the floor; its flag parser rejects the probe before any marker.
            case predatesProbe
            /// The client is older than 3.2 and rejects `-N`, so the probe never
            /// reached a daemon. It says nothing about the daemon; the
            /// executable's own release is the answer.
            case clientRejectsFlag
            case absent
            case failed(String)
        }

        static func interpret(probe reply: TmuxReply, marker: String) -> Probe {
            let prefix = "unknown command: \(marker)-"
            let lines = reply.errorText.split(separator: "\n", omittingEmptySubsequences: true)
            if reply.exitCode == 1, let line = lines.first(where: { $0.hasPrefix(prefix) }) {
                return .version(String(line.dropFirst(prefix.count)))
            }
            if isAbsentEndpoint(reply) { return .absent }
            if reply.exitCode != 0, reply.errorText.contains("unknown option -- N") {
                return .clientRejectsFlag
            }
            if reply.exitCode != 0, isPreThreeTwoAnswer(reply.errorText) { return .predatesProbe }
            let detail = reply.errorText.isEmpty ? reply.text : reply.errorText
            return .failed(detail.isEmpty ? "exit status \(reply.exitCode)" : detail)
        }

        /// The answers a daemon older than 3.2 gives the probe:
        /// - 3.1c parses `run-shell` with `bt:`, so `-C` is an unknown flag and
        ///   tmux prints the usage line;
        /// - 3.0a's server tells a newer client its version is too old.
        static func isPreThreeTwoAnswer(_ text: String) -> Bool {
            text.contains("run-shell: unknown flag -C")
                || text.contains("usage: run-shell")
                || isTooOldForClient(text)
        }

        /// What tmux says when nothing listens at the socket.
        static func isAbsentEndpoint(_ reply: TmuxReply) -> Bool {
            guard reply.exitCode != 0 else { return false }
            let text = reply.errorText
            if text.contains("no server running") { return true }
            return text.contains("error connecting to")
                && (text.contains("No such file or directory")
                    || text.contains("Connection refused"))
        }

        /// The executable's banner: tmux prints `tmux 3.4`, but 3.3a prints the
        /// name it was started as, so `tmux-3.3a 3.3a` is the same answer.
        static func executableToken(banner: String, executable: String) -> String? {
            let text = banner.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = URL(fileURLWithPath: executable).lastPathComponent
            for prefix in ["tmux ", name + " "] where text.hasPrefix(prefix) {
                let token = String(text.dropFirst(prefix.count))
                return token.contains("\n") ? nil : token
            }
            return nil
        }

        // MARK: Fence

        /// Holds a batch to the release that was checked.
        ///
        /// The condition is false only on a daemon that is not the checked
        /// release, and then the marker runs as a command, which tmux rejects and
        /// which ends the list before anything after it runs.
        static func fence(_ arguments: [String], to checked: ServerVersion, marker: String)
            -> [String]
        {
            fenceCommand(to: checked, marker: marker) + [";"]
                + (arguments.isEmpty ? ["new-session"] : arguments)
        }

        /// The fence alone, for a channel that already carries one command at a
        /// time.
        static func fenceCommand(to checked: ServerVersion, marker: String) -> [String] {
            ["if-shell", "-F", "#{==:#{version},\(checked.token)}", "", marker]
        }

        /// Nothing ran: the daemon either hit the fence's marker, or is a 3.0a
        /// that turned the client away before reading the command.
        static func isRefusal(_ reply: TmuxReply, marker: String) -> Bool {
            reply.errorText.split(separator: "\n").contains("unknown command: \(marker)")
                || (reply.exitCode != 0 && isTooOldForClient(reply.errorText))
        }

        static func isTooOldForClient(_ text: String) -> Bool {
            text.contains("server version is too old for client")
        }
    }
}

/// The release read for each endpoint, shared by every server value that
/// reaches it so a second handle does not spend a probe on a daemon the first
/// already read. A claim, not a lease: the fence on every batch is what
/// invalidates it.
final class VersionCache: @unchecked Sendable {
    struct Key: Hashable {
        let endpoint: Endpoint
        let executable: String
    }

    static let shared = VersionCache()

    private let lock = NSLock()
    private var daemons: [Key: ServerVersion] = [:]

    func daemon(for key: Key) -> ServerVersion? {
        lock.lock()
        defer { lock.unlock() }
        return daemons[key]
    }

    func record(_ version: ServerVersion?, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        daemons[key] = version
    }
}
