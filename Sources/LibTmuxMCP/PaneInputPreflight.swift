import Foundation
import LibTmux

enum PaneInputScope: Sendable {
    case configuredCohort
    case targetOnly
    case singularPOSIXShell
}

struct PaneInputResolution: Sendable {
    let source: Pane
    let configuredPanes: [Pane]

    var configuredPaneIDs: [PaneID] { configuredPanes.map(\.id) }
}

extension TmuxTools {
    static func resolvePaneInput(
        requested: PaneID,
        panes: [Pane],
        scope: PaneInputScope,
        callerGuard: CallerGuard,
        force: Bool
    ) throws -> PaneInputResolution {
        guard let source = panes.first(where: { $0.id == requested }) else {
            throw ToolError.refusedForSafety(
                "pane \(requested.rawValue) is stale; call list_panes again"
            )
        }

        let configured: [Pane]
        if scope == .targetOnly || !source.isSynchronized {
            configured = [source]
        } else {
            var unique: [PaneID: Pane] = [:]
            for pane in panes
            where pane.windowID == source.windowID && pane.isSynchronized {
                if unique[pane.id] == nil { unique[pane.id] = pane }
            }
            configured = unique.values.sorted { $0.id.rawValue < $1.id.rawValue }
        }

        for pane in configured {
            guard !pane.isDead else {
                throw ToolError.refusedForSafety(
                    "pane \(pane.id.rawValue) input is refused because its process is dead"
                )
            }
            guard pane.modeCount == 0 else {
                throw ToolError.refusedForSafety(
                    "pane \(pane.id.rawValue) input is refused while a human-owned mode is active; "
                        + "capture or snapshot the pane and wait for the mode to end"
                )
            }
            try callerGuard.checkPaneInput(pane.id, override: force)
        }

        if scope == .singularPOSIXShell {
            guard configured.count == 1 else {
                let ids = configured.map(\.id.rawValue).joined(separator: ", ")
                throw ToolError.refusedForSafety(
                    "run_shell_command requires one configured pane target; observed \(ids)"
                )
            }
            guard supportedPOSIXShell(source.currentCommand) else {
                throw ToolError.refusedForSafety(
                    "run_shell_command requires a supported POSIX shell in pane \(source.id.rawValue)"
                )
            }
        }
        return PaneInputResolution(source: source, configuredPanes: configured)
    }

    func preflightPaneInput(
        _ requested: String,
        scope: PaneInputScope,
        force: Bool,
        transitionFrom expected: PaneInputResolution? = nil,
        operation: String
    ) async throws -> PaneInputResolution {
        do {
            let snapshot = try await server.snapshot()
            let source: Pane
            if let paneID = PaneID(rawValue: requested),
                let pane = snapshot.panes.first(where: { $0.id == paneID })
            {
                source = pane
            } else {
                source = try WireReferenceCodec.processLocal.resolve(
                    requested,
                    among: snapshot.panes,
                    argument: "paneId",
                    refreshWith: "list_panes"
                )
            }
            let resolved = try Self.resolvePaneInput(
                requested: source.id,
                panes: snapshot.panes,
                scope: scope,
                callerGuard: guardForCaller(serverProcessID: snapshot.serverProcessID),
                force: force
            )
            if let expected {
                guard resolved.source.incarnation == expected.source.incarnation,
                    resolved.source.id == expected.source.id,
                    resolved.source.currentCommand == expected.source.currentCommand,
                    resolved.configuredPaneIDs == expected.configuredPaneIDs
                else {
                    throw ToolError.refusedForSafety("pane identity or input cohort changed")
                }
            }
            return resolved
        } catch {
            if expected != nil {
                if let tmuxError = error as? TmuxError, tmuxError == .cancelled { throw error }
                throw ToolError.refusedForSafety(
                    "\(operation) pane state changed after setup; no input was sent: \(error)"
                )
            }
            throw error
        }
    }

    static func requireSafeShellRoute(
        executable: String,
        socketPath: String
    ) throws {
        guard executable.hasPrefix("/"), socketPath.hasPrefix("/") else {
            throw ToolError.refusedForSafety(
                "run_shell_command requires an absolute tmux executable and socket path"
            )
        }
        guard !hasASCIIControl(executable), !hasASCIIControl(socketPath) else {
            throw ToolError.refusedForSafety(
                "run_shell_command refuses ASCII control bytes in its tmux route"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/printf") else {
            throw ToolError.refusedForSafety(
                "run_shell_command requires the supported host's /usr/bin/printf"
            )
        }
    }

    private static func supportedPOSIXShell(_ command: String) -> Bool {
        var name =
            command.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init)
            ?? command
        if name.first == "-" { name.removeFirst() }
        return ["sh", "ash", "bash", "dash", "ksh", "mksh", "pdksh", "zsh"].contains(name)
    }

    private static func hasASCIIControl(_ value: String) -> Bool {
        value.utf8.contains { $0 < 0x20 || $0 == 0x7f }
    }
}
