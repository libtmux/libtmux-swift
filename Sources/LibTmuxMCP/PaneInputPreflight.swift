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
    fileprivate let signature: PaneInputSignature

    var configuredPaneIDs: [PaneID] { configuredPanes.map(\.id) }
}

fileprivate struct PaneInputMemberSignature: Sendable, Hashable {
    let incarnation: ServerIncarnation
    let id: PaneID
    let windowID: WindowID
    let isSynchronized: Bool
    let isDead: Bool
    let isInputOff: Bool
    let modeCount: Int
    let currentCommand: String?

    init(_ pane: Pane, includeCommand: Bool) {
        self.incarnation = pane.incarnation
        self.id = pane.id
        self.windowID = pane.windowID
        self.isSynchronized = pane.isSynchronized
        self.isDead = pane.isDead
        self.isInputOff = pane.isInputOff
        self.modeCount = pane.modeCount
        self.currentCommand = includeCommand ? pane.currentCommand : nil
    }
}

fileprivate struct PaneInputLinkSignature: Sendable, Hashable {
    let incarnation: ServerIncarnation
    let sessionID: SessionID
    let windowID: WindowID
    let index: Int
    let isActive: Bool

    init(_ link: WindowLink) {
        self.incarnation = link.incarnation
        self.sessionID = link.sessionID
        self.windowID = link.windowID
        self.index = link.index
        self.isActive = link.isActive
    }
}

fileprivate struct PaneInputCallerSignature: Sendable, Hashable {
    let identity: CallerIdentity?
    let isSameServer: Bool
}

fileprivate struct PaneInputSignature: Sendable, Hashable {
    let source: PaneInputMemberSignature
    let configuredPanes: [PaneInputMemberSignature]
    let windowLinks: [PaneInputLinkSignature]
    let caller: PaneInputCallerSignature
}

extension TmuxTools {
    static func resolvePaneInput(
        requested: PaneID,
        snapshot: Snapshot,
        scope: PaneInputScope,
        callerGuard: CallerGuard,
        force: Bool
    ) throws -> PaneInputResolution {
        try callerGuard.validate(in: snapshot)
        let panes = snapshot.panes
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

        let attended = try attendedPaneIDs(in: snapshot)

        for pane in configured {
            guard pane.incarnation == snapshot.incarnation else {
                throw ToolError.refusedForSafety(
                    "pane \(pane.id.rawValue) input context is incomplete or inconsistent"
                )
            }
            guard !pane.isDead else {
                throw ToolError.refusedForSafety(
                    "pane \(pane.id.rawValue) input is refused because its process is dead"
                )
            }
            guard !pane.isInputOff else {
                throw ToolError.refusedForSafety(
                    "pane \(pane.id.rawValue) input is refused because tmux disabled input"
                )
            }
            guard pane.modeCount == 0 else {
                throw ToolError.refusedForSafety(
                    "pane \(pane.id.rawValue) input is refused while a human-owned mode is active; "
                        + "capture or snapshot the pane and wait for the mode to end"
                )
            }
            guard !attended.contains(pane.id) else {
                throw ToolError.refusedForSafety(
                    "pane \(pane.id.rawValue) input is refused because a terminal client attends it"
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
        let windowLinks = try paneInputWindowLinks(
            for: Set(configured.map(\.windowID)),
            in: snapshot
        )
        let includeCommand = scope == .singularPOSIXShell
        return PaneInputResolution(
            source: source,
            configuredPanes: configured,
            signature: PaneInputSignature(
                source: PaneInputMemberSignature(source, includeCommand: includeCommand),
                configuredPanes: configured.map {
                    PaneInputMemberSignature($0, includeCommand: includeCommand)
                },
                windowLinks: windowLinks.map(PaneInputLinkSignature.init),
                caller: PaneInputCallerSignature(
                    identity: callerGuard.identity,
                    isSameServer: callerGuard.isSameServer
                )
            )
        )
    }

    private static func paneInputWindowLinks(
        for windowIDs: Set<WindowID>,
        in snapshot: Snapshot
    ) throws -> [WindowLink] {
        for windowID in windowIDs {
            guard
                snapshot.windows.filter({
                    $0.incarnation == snapshot.incarnation && $0.id == windowID
                }).count == 1
            else {
                throw ToolError.refusedForSafety(
                    "pane input window placement is incomplete or inconsistent"
                )
            }
        }
        let links = snapshot.windowLinks.filter { windowIDs.contains($0.windowID) }
        guard !links.isEmpty,
            links.allSatisfy({ $0.incarnation == snapshot.incarnation }),
            Set(links.map(\.id)).count == links.count,
            links.allSatisfy({ link in
                snapshot.sessions.filter {
                    $0.incarnation == snapshot.incarnation && $0.id == link.sessionID
                }.count == 1
            })
        else {
            throw ToolError.refusedForSafety(
                "pane input window placement is incomplete or inconsistent"
            )
        }
        return links.sorted { left, right in
            if left.sessionID != right.sessionID {
                return left.sessionID.rawValue < right.sessionID.rawValue
            }
            if left.index != right.index { return left.index < right.index }
            if left.windowID != right.windowID {
                return left.windowID.rawValue < right.windowID.rawValue
            }
            return !left.isActive && right.isActive
        }
    }

    private static func attendedPaneIDs(in snapshot: Snapshot) throws -> Set<PaneID> {
        var attended: Set<PaneID> = []
        for client in snapshot.clients {
            guard client.incarnation == snapshot.incarnation else {
                throw ToolError.refusedForSafety(
                    "client attention context is incomplete or inconsistent"
                )
            }
            guard !client.isControlMode else { continue }
            guard
                let paneID = client.activePaneID,
                let isZoomed = client.isWindowZoomed,
                snapshot.sessions.filter({
                    $0.incarnation == snapshot.incarnation && $0.id == client.sessionID
                }).count == 1
            else {
                throw ToolError.refusedForSafety(
                    "client attention context is incomplete or inconsistent"
                )
            }

            let activePanes = snapshot.panes.filter {
                $0.incarnation == snapshot.incarnation && $0.id == paneID
            }
            let activeLinks = snapshot.windowLinks.filter {
                $0.incarnation == snapshot.incarnation
                    && $0.sessionID == client.sessionID && $0.isActive
            }
            guard activePanes.count == 1,
                let activePane = activePanes.first,
                activePane.isActive,
                activeLinks.count == 1,
                activeLinks[0].windowID == activePane.windowID,
                snapshot.windows.filter({
                    $0.incarnation == snapshot.incarnation && $0.id == activePane.windowID
                }).count == 1
            else {
                throw ToolError.refusedForSafety(
                    "client attention context is incomplete or inconsistent"
                )
            }
            if isZoomed {
                attended.insert(paneID)
            } else {
                let visible = snapshot.panes.filter {
                    $0.incarnation == snapshot.incarnation
                        && $0.windowID == activePane.windowID
                }
                guard !visible.isEmpty, Set(visible.map(\.id)).count == visible.count else {
                    throw ToolError.refusedForSafety(
                        "client attention context is incomplete or inconsistent"
                    )
                }
                attended.formUnion(visible.map(\.id))
            }
        }
        return attended
    }

    func preflightPaneInput(
        _ requested: String,
        scope: PaneInputScope,
        force: Bool,
        transitionFrom expected: PaneInputResolution? = nil,
        reservation: PaneInputReservation? = nil,
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
                snapshot: snapshot,
                scope: scope,
                callerGuard: guardForCaller(serverIncarnation: snapshot.incarnation),
                force: force
            )
            if let expected {
                guard resolved.signature == expected.signature else {
                    throw ToolError.refusedForSafety("pane identity or input cohort changed")
                }
            }
            guard
                await Self.paneRuns.permits(
                    resolved.configuredPanes,
                    owner: reservation
                )
            else {
                throw ToolError.refusedForSafety(
                    "\(operation) is refused while another pane input operation is active"
                )
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

    static func reservePaneInput(
        _ resolved: PaneInputResolution,
        operation: String
    ) async throws -> PaneInputReservation {
        guard let reservation = await paneRuns.reserve(resolved.configuredPanes) else {
            throw ToolError.refusedForSafety(
                "\(operation) is refused while another pane input operation is active"
            )
        }
        return reservation
    }

    static func requireSafeShellRoute(
        executable: String,
        socketPath: String,
        requiringTrapCapture: Bool = false
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
        var utilities = ["/usr/bin/printf"]
        if requiringTrapCapture {
            utilities += ["/bin/rm", "/usr/bin/head", "/usr/bin/mktemp"]
        }
        guard utilities.allSatisfy(FileManager.default.isExecutableFile) else {
            throw ToolError.refusedForSafety(
                "run_shell_command requires its supported host utilities"
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
