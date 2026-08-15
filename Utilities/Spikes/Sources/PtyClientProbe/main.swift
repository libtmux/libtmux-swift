import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

package struct PtyClientReadiness: Codable, Sendable {
    package let protocolVersion: Int
    package let probePID: Int32
    package let childPID: Int32
    package let childParentPID: Int32
    package let childProcessGroupID: Int32
    package let childWasStoppedBeforeReadiness: Bool
    package let ptyPath: String
    package let rows: Int
    package let columns: Int
}

package enum PtyBootstrapObservation: Equatable, Sendable {
    case stopped(Int32)
    case terminalPinned
}

package enum PtyBootstrapWaitObservation: Sendable {
    case event(processIdentifier: pid_t, code: Int, status: Int32)
    case failed(Int32)
}

package struct PtyBootstrapObservationHooks: Sendable {
    let waitForBootstrap: @Sendable (pid_t) -> PtyBootstrapWaitObservation
    let signalChild: @Sendable (pid_t, Int32) -> Int32

    package init(
        waitForBootstrap: (@Sendable (pid_t) -> PtyBootstrapWaitObservation)? = nil,
        signalChild: @escaping @Sendable (pid_t, Int32) -> Int32 = {
            processIdentifier, signal in
            guard kill(processIdentifier, signal) == 0 else { return errno }
            return 0
        }
    ) {
        self.waitForBootstrap = waitForBootstrap ?? observePtyBootstrapWait
        self.signalChild = signalChild
    }
}

private struct PtyInvocation {
    let rows: Int
    let columns: Int
    let executable: String
    let arguments: [String]
}

private struct AllocatedPty {
    let master: Int32
    let slave: Int32
    let path: String
}

package enum PtyProbeError: Error {
    case deadlineExceeded
    case invalidArguments
    case invalidProcessRelationship
    case posix(operation: String, code: Int32)
}

private enum PtyProbeOutcome {
    case child(Int32)
    case endOfInput
    case externalSignal(Int32)
}

package enum PtyChildTerminalObservation: Sendable {
    case pending
    case pinned
    case failed(Int32)
}

package struct PtyChildSupervisorHooks: Sendable {
    let observeTerminal: @Sendable (pid_t) -> PtyChildTerminalObservation
    let signalProcessGroup: @Sendable (pid_t, Int32) -> Int32

    package init(
        observeTerminal: (@Sendable (pid_t) -> PtyChildTerminalObservation)? = nil,
        signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Int32 = {
            processGroup, signal in
            guard kill(-processGroup, signal) == 0 else { return errno }
            return 0
        }
    ) {
        self.observeTerminal = observeTerminal ?? observePtyChildTerminal
        self.signalProcessGroup = signalProcessGroup
    }
}

package final class PtyChildSupervisor {
    private var master: Int32?
    private let child: pid_t
    private let processGroup: pid_t
    private let hooks: PtyChildSupervisorHooks
    private var terminalObserved = false
    private var reaped = false
    private var reapedStatus: Int32?
    private var useWaitPIDRecovery = false
    private var ownershipLost = false

    package init(
        master: Int32?,
        child: pid_t,
        processGroup: pid_t,
        hooks: PtyChildSupervisorHooks = PtyChildSupervisorHooks()
    ) {
        self.master = master
        self.child = child
        self.processGroup = processGroup
        self.hooks = hooks
    }

    func resumeAfterReadiness() throws {
        try signalOwnedGroup(SIGCONT)
    }

    fileprivate func forward(untilSignalIn signalSet: inout sigset_t) throws -> PtyProbeOutcome {
        do {
            while true {
                if let signal = try consumePendingTerminationSignal(from: &signalSet) {
                    _ = try stopAndReap(initialSignal: signal)
                    return .externalSignal(signal)
                }
                if try observeTerminalChild() {
                    try drainTerminalMaster()
                    return .child(try reapTerminalChild())
                }

                var descriptors = [
                    pollfd(
                        fd: STDIN_FILENO,
                        events: Int16(POLLIN | POLLHUP | POLLERR),
                        revents: 0
                    ),
                    pollfd(
                        fd: master ?? -1,
                        events: Int16(POLLIN | POLLHUP | POLLERR),
                        revents: 0
                    ),
                ]
                let result = descriptors.withUnsafeMutableBufferPointer { buffer in
                    poll(buffer.baseAddress, nfds_t(buffer.count), 10)
                }
                guard result >= 0 || errno == EINTR else {
                    throw PtyProbeError.posix(operation: "poll", code: errno)
                }
                guard result > 0 else { continue }
                if let signal = try consumePendingTerminationSignal(from: &signalSet) {
                    _ = try stopAndReap(initialSignal: signal)
                    return .externalSignal(signal)
                }

                if descriptors[1].revents & Int16(POLLNVAL) != 0 {
                    throw PtyProbeError.posix(operation: "poll-master", code: EBADF)
                }
                if descriptors[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                    try forwardMasterOnce()
                }

                if descriptors[0].revents & Int16(POLLNVAL | POLLERR) != 0 {
                    throw PtyProbeError.posix(operation: "poll-stdin", code: EBADF)
                }
                if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                    if try forwardStandardInputOnce() {
                        _ = try stopAndReap(initialSignal: SIGTERM)
                        return .endOfInput
                    }
                }
            }
        } catch {
            _ = try? stopAndReap(initialSignal: SIGTERM)
            throw error
        }
    }

    package func stopAndReap(initialSignal: Int32) throws -> Int32 {
        if let reapedStatus { return reapedStatus }

        var firstError: (any Error)?
        do {
            _ = try observeTerminalChild()
        } catch {
            firstError = error
            recoverAfterTerminalObservationFailure()
        }

        if ownershipLost {
            closeMaster()
            throw firstError ?? PtyProbeError.invalidProcessRelationship
        }
        if useWaitPIDRecovery, let firstError {
            return try stopAndReapWithPinnedWaitPID(
                initialSignal: initialSignal,
                originalError: firstError
            )
        }

        if !terminalObserved {
            for signal in [initialSignal, SIGCONT] {
                do {
                    try signalOwnedGroup(signal)
                } catch  where firstError == nil {
                    firstError = error
                } catch {}
            }
            waitForTerminal(
                until: monotonicMilliseconds() + 250,
                firstError: &firstError
            )
        }

        if !reaped,
            !terminalObserved || processGroupHasLiveMembers(excluding: child)
        {
            do {
                try signalOwnedGroup(SIGKILL)
            } catch  where firstError == nil {
                firstError = error
            } catch {}
        }

        let terminalDeadline = monotonicMilliseconds() + 2_000
        waitForTerminal(until: terminalDeadline, firstError: &firstError)
        guard terminalObserved else {
            closeMaster()
            throw firstError ?? PtyProbeError.deadlineExceeded
        }

        let masterDrained = pumpMaster(
            until: monotonicMilliseconds() + 2_000,
            firstError: &firstError
        )
        if !masterDrained, firstError == nil {
            firstError = PtyProbeError.deadlineExceeded
        }
        let status = try reapTerminalChild()
        reapedStatus = status
        closeMaster()
        if let firstError { throw firstError }
        return status
    }

    private func observeTerminalChild() throws -> Bool {
        if terminalObserved { return true }
        if useWaitPIDRecovery {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                errno = 0
                result = waitpid(child, &status, WNOHANG)
            } while result < 0 && errno == EINTR
            if result == 0 { return false }
            guard result == child else {
                ownershipLost = true
                throw PtyProbeError.posix(operation: "waitpid", code: errno)
            }
            terminalObserved = true
            reaped = true
            reapedStatus = status
            return true
        }

        switch hooks.observeTerminal(child) {
        case .pending:
            return false
        case .pinned:
            terminalObserved = true
            return true
        case let .failed(code):
            throw PtyProbeError.posix(operation: "waitid", code: code)
        }
    }

    private func signalOwnedGroup(_ signal: Int32) throws {
        guard child > 0, processGroup == child, !reaped, !ownershipLost else {
            throw PtyProbeError.invalidProcessRelationship
        }
        let code = hooks.signalProcessGroup(processGroup, signal)
        guard code == 0 || code == ESRCH else {
            throw PtyProbeError.posix(operation: "kill", code: code)
        }
    }

    private func reapTerminalChild() throws -> Int32 {
        if reaped, let reapedStatus { return reapedStatus }
        guard terminalObserved, !reaped else {
            throw PtyProbeError.invalidProcessRelationship
        }
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(child, &status, 0)
        } while result < 0 && errno == EINTR
        guard result == child else {
            throw PtyProbeError.posix(operation: "waitpid", code: errno)
        }
        reaped = true
        reapedStatus = status
        return status
    }

    private func recoverAfterTerminalObservationFailure() {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            errno = 0
            result = waitpid(child, &status, WNOHANG)
        } while result < 0 && errno == EINTR

        if result == child {
            terminalObserved = true
            reaped = true
            reapedStatus = status
        } else if result == 0 {
            useWaitPIDRecovery = true
        } else {
            ownershipLost = true
        }
    }

    private func stopAndReapWithPinnedWaitPID(
        initialSignal: Int32,
        originalError: any Error
    ) throws -> Int32 {
        var firstError: (any Error)? = originalError
        for signal in [initialSignal, SIGCONT] {
            do {
                try signalOwnedGroup(signal)
            } catch  where firstError == nil {
                firstError = error
            } catch {}
        }

        waitWithoutTerminalObservation(
            until: monotonicMilliseconds() + 250,
            firstError: &firstError
        )
        do {
            try signalOwnedGroup(SIGKILL)
        } catch  where firstError == nil {
            firstError = error
        } catch {}

        let masterDrained = pumpMaster(
            until: monotonicMilliseconds() + 2_000,
            firstError: &firstError
        )
        if !masterDrained, firstError == nil {
            firstError = PtyProbeError.deadlineExceeded
        }
        let status = try reapChildAfterOwnedGroupKill()
        reapedStatus = status
        closeMaster()
        if let firstError { throw firstError }
        return status
    }

    private func waitWithoutTerminalObservation(
        until deadline: UInt64,
        firstError: inout (any Error)?
    ) {
        while monotonicMilliseconds() < deadline {
            let now = monotonicMilliseconds()
            let sliceDeadline = min(now + 10, deadline)
            if master != nil {
                _ = pumpMaster(
                    until: sliceDeadline,
                    firstError: &firstError
                )
            } else {
                _ = poll(nil, 0, Int32(sliceDeadline - now))
            }
        }
    }

    private func reapChildAfterOwnedGroupKill() throws -> Int32 {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            errno = 0
            result = waitpid(child, &status, 0)
        } while result < 0 && errno == EINTR
        guard result == child else {
            ownershipLost = true
            throw PtyProbeError.posix(operation: "waitpid", code: errno)
        }
        terminalObserved = true
        reaped = true
        return status
    }

    private func waitForTerminal(
        until deadline: UInt64,
        firstError: inout (any Error)?
    ) {
        while !terminalObserved, monotonicMilliseconds() < deadline {
            do {
                terminalObserved = try observeTerminalChild()
            } catch  where firstError == nil {
                firstError = error
            } catch {}
            if !terminalObserved {
                _ = pumpMaster(
                    until: min(monotonicMilliseconds() + 10, deadline),
                    firstError: &firstError
                )
            }
        }
    }

    private func forwardStandardInputOnce() throws -> Bool {
        guard let master else { return true }
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        let count = bytes.withUnsafeMutableBytes {
            read(STDIN_FILENO, $0.baseAddress, $0.count)
        }
        if count > 0 {
            try writeAll(Array(bytes[..<count]), to: master)
            return false
        }
        if count == 0 { return true }
        if errno == EINTR { return false }
        throw PtyProbeError.posix(operation: "read-stdin", code: errno)
    }

    private func forwardMasterOnce() throws {
        guard let master else { return }
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        let count = bytes.withUnsafeMutableBytes {
            read(master, $0.baseAddress, $0.count)
        }
        if count > 0 {
            try writeAll(Array(bytes[..<count]), to: STDERR_FILENO)
        } else if count == 0 || errno == EIO {
            closeMaster()
        } else if errno != EINTR {
            throw PtyProbeError.posix(operation: "read-master", code: errno)
        }
    }

    private func drainTerminalMaster() throws {
        var firstError: (any Error)?
        let drained = pumpMaster(
            until: monotonicMilliseconds() + 2_000,
            firstError: &firstError
        )
        if let firstError { throw firstError }
        guard drained else { throw PtyProbeError.deadlineExceeded }
    }

    @discardableResult
    private func pumpMaster(
        until deadline: UInt64,
        firstError: inout (any Error)?
    ) -> Bool {
        while master != nil, monotonicMilliseconds() < deadline {
            let now = monotonicMilliseconds()
            guard now < deadline else { return master == nil }
            var descriptor = pollfd(
                fd: master ?? -1,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let remaining = deadline - now
            let timeout = Int32(min(remaining, 10))
            let result = poll(&descriptor, 1, timeout)
            if result < 0 {
                if errno == EINTR { continue }
                if firstError == nil {
                    firstError = PtyProbeError.posix(operation: "poll-master", code: errno)
                }
                return false
            }
            if result == 0 { continue }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                if firstError == nil {
                    firstError = PtyProbeError.posix(operation: "poll-master", code: EBADF)
                }
                return false
            }
            if descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                do {
                    try forwardMasterOnce()
                } catch {
                    if firstError == nil { firstError = error }
                    return false
                }
            }
        }
        return master == nil
    }

    private func closeMaster() {
        guard let master else { return }
        self.master = nil
        _ = close(master)
    }
}

private func observePtyChildTerminal(_ child: pid_t) -> PtyChildTerminalObservation {
    var information = siginfo_t()
    var result: Int32
    repeat {
        errno = 0
        result = waitid(
            P_PID,
            id_t(child),
            &information,
            WEXITED | WNOHANG | WNOWAIT
        )
    } while result != 0 && errno == EINTR
    guard result == 0 else { return .failed(errno) }
    return information.si_signo == SIGCHLD ? .pinned : .pending
}

private func parseInvocation(_ arguments: [String]) throws -> PtyInvocation {
    guard arguments.count >= 6,
        arguments[0] == "--rows",
        let rows = Int(arguments[1]), rows > 0, rows <= Int(UInt16.max),
        arguments[2] == "--columns",
        let columns = Int(arguments[3]), columns > 0, columns <= Int(UInt16.max),
        arguments[4] == "--",
        arguments[5].hasPrefix("/")
    else {
        throw PtyProbeError.invalidArguments
    }
    return PtyInvocation(
        rows: rows,
        columns: columns,
        executable: arguments[5],
        arguments: Array(arguments.dropFirst(6))
    )
}

private func allocatePty(rows: Int, columns: Int) throws -> AllocatedPty {
    var master: Int32 = -1
    var slave: Int32 = -1
    guard openpty(&master, &slave, nil, nil, nil) == 0 else {
        throw PtyProbeError.posix(operation: "openpty", code: errno)
    }
    do {
        try setCloseOnExec(master)
        try setCloseOnExec(slave)

        var attributes = termios()
        guard tcgetattr(slave, &attributes) == 0 else {
            throw PtyProbeError.posix(operation: "tcgetattr", code: errno)
        }
        cfmakeraw(&attributes)
        guard tcsetattr(slave, TCSANOW, &attributes) == 0 else {
            throw PtyProbeError.posix(operation: "tcsetattr", code: errno)
        }

        var size = winsize()
        size.ws_row = UInt16(rows)
        size.ws_col = UInt16(columns)
        guard ioctl(slave, UInt(TIOCSWINSZ), &size) == 0 else {
            throw PtyProbeError.posix(operation: "ioctl", code: errno)
        }

        var pathBytes = [CChar](repeating: 0, count: 1_024)
        let nameResult = pathBytes.withUnsafeMutableBufferPointer { buffer in
            ttyname_r(slave, buffer.baseAddress!, buffer.count)
        }
        guard nameResult == 0 else {
            throw PtyProbeError.posix(operation: "ttyname_r", code: nameResult)
        }
        let pathEnd = pathBytes.firstIndex(of: 0) ?? pathBytes.endIndex
        let path = String(
            decoding: pathBytes[..<pathEnd].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard path.hasPrefix("/dev/") else {
            throw PtyProbeError.invalidProcessRelationship
        }
        return AllocatedPty(
            master: master,
            slave: slave,
            path: path
        )
    } catch {
        _ = close(master)
        _ = close(slave)
        throw error
    }
}

private func setCloseOnExec(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFD)
    guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
        throw PtyProbeError.posix(operation: "fcntl", code: errno)
    }
}

private func spawnPtyChild(
    invocation: PtyInvocation,
    pty: AllocatedPty,
    probeExecutable: String
) throws -> pid_t {
    #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
    #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
    #endif
    var actionsInitialized = false
    var attributesInitialized = false
    defer {
        if actionsInitialized { _ = posix_spawn_file_actions_destroy(&actions) }
        if attributesInitialized { _ = posix_spawnattr_destroy(&attributes) }
    }

    var code = posix_spawn_file_actions_init(&actions)
    guard code == 0 else {
        throw PtyProbeError.posix(operation: "posix_spawn_file_actions_init", code: code)
    }
    actionsInitialized = true
    code = posix_spawnattr_init(&attributes)
    guard code == 0 else {
        throw PtyProbeError.posix(operation: "posix_spawnattr_init", code: code)
    }
    attributesInitialized = true

    for destination in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        code = posix_spawn_file_actions_adddup2(&actions, pty.slave, destination)
        guard code == 0 else {
            throw PtyProbeError.posix(operation: "posix_spawn_file_actions_adddup2", code: code)
        }
    }
    #if canImport(Darwin)
        for descriptor in [pty.master, pty.slave] where descriptor > STDERR_FILENO {
            code = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard code == 0 else {
                throw PtyProbeError.posix(
                    operation: "posix_spawn_file_actions_addclose",
                    code: code
                )
            }
        }
    #else
        code = posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1)
        guard code == 0 else {
            throw PtyProbeError.posix(
                operation: "posix_spawn_file_actions_addclosefrom_np",
                code: code
            )
        }
    #endif

    var emptyMask = sigset_t()
    guard sigemptyset(&emptyMask) == 0 else {
        throw PtyProbeError.posix(operation: "sigemptyset", code: errno)
    }
    code = posix_spawnattr_setsigmask(&attributes, &emptyMask)
    guard code == 0 else {
        throw PtyProbeError.posix(operation: "posix_spawnattr_setsigmask", code: code)
    }
    var defaultSignals = sigset_t()
    guard sigemptyset(&defaultSignals) == 0 else {
        throw PtyProbeError.posix(operation: "sigemptyset", code: errno)
    }
    for signal in [SIGHUP, SIGINT, SIGTERM, SIGPIPE] {
        guard sigaddset(&defaultSignals, signal) == 0 else {
            throw PtyProbeError.posix(operation: "sigaddset", code: errno)
        }
    }
    code = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    guard code == 0 else {
        throw PtyProbeError.posix(operation: "posix_spawnattr_setsigdefault", code: code)
    }
    code = posix_spawnattr_setpgroup(&attributes, 0)
    guard code == 0 else {
        throw PtyProbeError.posix(operation: "posix_spawnattr_setpgroup", code: code)
    }
    var flags =
        Int16(POSIX_SPAWN_SETSIGMASK)
        | Int16(POSIX_SPAWN_SETSIGDEF)
        | Int16(POSIX_SPAWN_SETPGROUP)
    #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif
    code = posix_spawnattr_setflags(&attributes, flags)
    guard code == 0 else {
        throw PtyProbeError.posix(operation: "posix_spawnattr_setflags", code: code)
    }

    let argv =
        [
            probeExecutable,
            "--bootstrap-child",
            "--",
            invocation.executable,
        ] + invocation.arguments
    let environment = ProcessInfo.processInfo.environment.keys.sorted().map {
        "\($0)=\(ProcessInfo.processInfo.environment[$0]!)"
    }
    var child: pid_t = 0
    code = try withCStringArray(argv) { argumentPointers in
        try withCStringArray(environment) { environmentPointers in
            posix_spawn(
                &child,
                probeExecutable,
                &actions,
                &attributes,
                argumentPointers,
                environmentPointers
            )
        }
    }
    guard code == 0 else {
        throw PtyProbeError.posix(operation: "posix_spawn", code: code)
    }
    return child
}

private func runBootstrapChild(_ arguments: [String]) throws -> Never {
    guard arguments.count >= 3,
        arguments[0] == "--bootstrap-child",
        arguments[1] == "--",
        arguments[2].hasPrefix("/")
    else {
        throw PtyProbeError.invalidArguments
    }

    guard raise(SIGSTOP) == 0 else {
        throw PtyProbeError.posix(operation: "raise", code: errno)
    }

    let executable = arguments[2]
    let argv = [executable] + Array(arguments.dropFirst(3))
    let environment = ProcessInfo.processInfo.environment.keys.sorted().map {
        "\($0)=\(ProcessInfo.processInfo.environment[$0]!)"
    }
    _ = try withCStringArray(argv) { argumentPointers in
        try withCStringArray(environment) { environmentPointers in
            execve(executable, argumentPointers, environmentPointers)
        }
    }
    throw PtyProbeError.posix(operation: "execve", code: errno)
}

package func observePtyBootstrapChild(
    _ child: pid_t,
    hooks: PtyBootstrapObservationHooks = PtyBootstrapObservationHooks()
) throws -> PtyBootstrapObservation {
    switch hooks.waitForBootstrap(child) {
    case let .event(processIdentifier, code, status):
        guard processIdentifier == child else {
            try recoverPtyBootstrapChildAfterObservationFailure(child, hooks: hooks)
            throw PtyProbeError.invalidProcessRelationship
        }
        switch code {
        case CLD_STOPPED:
            return .stopped(status)
        case CLD_EXITED, CLD_KILLED, CLD_DUMPED:
            return .terminalPinned
        default:
            try recoverPtyBootstrapChildAfterObservationFailure(child, hooks: hooks)
            throw PtyProbeError.invalidProcessRelationship
        }
    case let .failed(code):
        try recoverPtyBootstrapChildAfterObservationFailure(child, hooks: hooks)
        throw PtyProbeError.posix(operation: "waitid", code: code)
    }
}

package func reapPinnedPtyBootstrapChild(_ child: pid_t) throws -> Int32 {
    var status: Int32 = 0
    var result: pid_t
    repeat {
        errno = 0
        result = waitpid(child, &status, 0)
    } while result < 0 && errno == EINTR
    guard result == child else {
        throw PtyProbeError.posix(operation: "waitpid", code: errno)
    }
    return status
}

private func observePtyBootstrapWait(_ child: pid_t) -> PtyBootstrapWaitObservation {
    var information = siginfo_t()
    var result: Int32
    repeat {
        errno = 0
        result = waitid(
            P_PID,
            id_t(child),
            &information,
            WSTOPPED | WEXITED | WNOWAIT
        )
    } while result != 0 && errno == EINTR
    guard result == 0 else { return .failed(errno) }
    return .event(
        processIdentifier: ptyBootstrapSignalInfoProcessIdentifier(information),
        code: Int(information.si_code),
        status: ptyBootstrapSignalInfoStatus(information)
    )
}

private func ptyBootstrapSignalInfoProcessIdentifier(_ information: siginfo_t) -> pid_t {
    #if os(Linux)
        information._sifields._sigchld.si_pid
    #elseif canImport(Darwin)
        information.si_pid
    #else
        0
    #endif
}

private func ptyBootstrapSignalInfoStatus(_ information: siginfo_t) -> Int32 {
    #if os(Linux)
        information._sifields._sigchld.si_status
    #elseif canImport(Darwin)
        information.si_status
    #else
        0
    #endif
}

private func recoverPtyBootstrapChildAfterObservationFailure(
    _ child: pid_t,
    hooks: PtyBootstrapObservationHooks
) throws {
    var status: Int32 = 0
    var result: pid_t
    repeat {
        errno = 0
        result = waitpid(child, &status, WNOHANG)
    } while result < 0 && errno == EINTR

    if result == child { return }
    if result == 0 {
        let signalError = hooks.signalChild(child, SIGKILL)
        guard signalError == 0 || signalError == ESRCH else {
            throw PtyProbeError.posix(operation: "kill", code: signalError)
        }
        _ = try reapPinnedPtyBootstrapChild(child)
        return
    }
    throw PtyProbeError.posix(operation: "waitpid", code: errno)
}

private func withCStringArray<Result>(
    _ strings: [String],
    body: ([UnsafeMutablePointer<CChar>?]) throws -> Result
) throws -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    defer { pointers.forEach { free($0) } }
    for string in strings {
        guard let pointer = strdup(string) else {
            throw PtyProbeError.posix(operation: "strdup", code: ENOMEM)
        }
        pointers.append(pointer)
    }
    pointers.append(nil)
    return try body(pointers)
}

private func managedSignalSet() throws -> sigset_t {
    var signalSet = sigset_t()
    guard sigemptyset(&signalSet) == 0 else {
        throw PtyProbeError.posix(operation: "sigemptyset", code: errno)
    }
    for signal in [SIGHUP, SIGINT, SIGTERM, SIGPIPE] {
        guard sigaddset(&signalSet, signal) == 0 else {
            throw PtyProbeError.posix(operation: "sigaddset", code: errno)
        }
    }
    let result = pthread_sigmask(SIG_BLOCK, &signalSet, nil)
    guard result == 0 else {
        throw PtyProbeError.posix(operation: "pthread_sigmask", code: result)
    }
    return signalSet
}

private func consumePendingTerminationSignal(
    from signalSet: inout sigset_t
) throws -> Int32? {
    var pending = sigset_t()
    guard sigpending(&pending) == 0 else {
        throw PtyProbeError.posix(operation: "sigpending", code: errno)
    }
    for signal in [SIGHUP, SIGINT, SIGTERM] {
        let membership = sigismember(&pending, signal)
        guard membership >= 0 else {
            throw PtyProbeError.posix(operation: "sigismember", code: errno)
        }
        if membership == 1 {
            var received: Int32 = 0
            let result = sigwait(&signalSet, &received)
            guard result == 0, received == signal else {
                throw PtyProbeError.posix(
                    operation: "sigwait",
                    code: result == 0 ? EINVAL : result
                )
            }
            return signal
        }
    }
    return nil
}

private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = write(
                descriptor,
                buffer.baseAddress!.advanced(by: offset),
                buffer.count - offset
            )
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw PtyProbeError.posix(operation: "write", code: errno)
            }
        }
    }
}

private func monotonicMilliseconds() -> UInt64 {
    var time = timespec()
    guard clock_gettime(CLOCK_MONOTONIC, &time) == 0 else { return 0 }
    return UInt64(time.tv_sec) * 1_000 + UInt64(time.tv_nsec) / 1_000_000
}

private func processGroupHasLiveMembers(excluding child: pid_t) -> Bool {
    #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
            return true
        }
        for entry in entries {
            guard let processIdentifier = pid_t(entry), processIdentifier != child,
                let record = try? String(
                    contentsOfFile: "/proc/\(entry)/stat",
                    encoding: .utf8
                ),
                let closingParenthesis = record.lastIndex(of: ")")
            else {
                continue
            }
            let fields = record[record.index(after: closingParenthesis)...]
                .split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 3,
                fields[0] != "Z",
                fields[0] != "X",
                pid_t(fields[2]) == child
            else {
                continue
            }
            return true
        }
        return false
    #else
        errno = 0
        let result = kill(-child, 0)
        return result == 0 || errno == EPERM
    #endif
}

private func runProbe(
    readinessPublished: () -> Void
) throws -> PtyProbeOutcome {
    let invocation = try parseInvocation(Array(CommandLine.arguments.dropFirst()))
    var signalSet = try managedSignalSet()
    let probe = getpid()
    guard probe > 0 else { throw PtyProbeError.invalidProcessRelationship }

    let pty = try allocatePty(rows: invocation.rows, columns: invocation.columns)
    let child: pid_t
    do {
        guard let probeExecutable = CommandLine.arguments.first,
            probeExecutable.hasPrefix("/")
        else {
            throw PtyProbeError.invalidProcessRelationship
        }
        child = try spawnPtyChild(
            invocation: invocation,
            pty: pty,
            probeExecutable: probeExecutable
        )
    } catch {
        _ = close(pty.master)
        _ = close(pty.slave)
        throw error
    }
    _ = close(pty.slave)

    let bootstrapObservation: PtyBootstrapObservation
    do {
        bootstrapObservation = try observePtyBootstrapChild(child)
    } catch {
        _ = close(pty.master)
        throw error
    }
    switch bootstrapObservation {
    case let .stopped(signal) where signal == SIGSTOP && getpgid(child) == child:
        break
    case .terminalPinned:
        _ = close(pty.master)
        _ = try reapPinnedPtyBootstrapChild(child)
        throw PtyProbeError.invalidProcessRelationship
    case .stopped:
        _ = close(pty.master)
        try recoverPtyBootstrapChildAfterObservationFailure(
            child,
            hooks: PtyBootstrapObservationHooks()
        )
        throw PtyProbeError.invalidProcessRelationship
    }

    let supervisor = PtyChildSupervisor(
        master: pty.master,
        child: child,
        processGroup: child
    )
    do {
        if let signal = try consumePendingTerminationSignal(from: &signalSet) {
            _ = try supervisor.stopAndReap(initialSignal: signal)
            return .externalSignal(signal)
        }
        let readiness = PtyClientReadiness(
            protocolVersion: 1,
            probePID: probe,
            childPID: child,
            childParentPID: probe,
            childProcessGroupID: child,
            childWasStoppedBeforeReadiness: true,
            ptyPath: pty.path,
            rows: invocation.rows,
            columns: invocation.columns
        )
        var encoded = try JSONEncoder().encode(readiness)
        encoded.append(UInt8(ascii: "\n"))
        try writeAll(Array(encoded), to: STDOUT_FILENO)
        guard close(STDOUT_FILENO) == 0 else {
            throw PtyProbeError.posix(operation: "close-stdout", code: errno)
        }
        readinessPublished()
        try supervisor.resumeAfterReadiness()
        return try supervisor.forward(untilSignalIn: &signalSet)
    } catch {
        _ = try? supervisor.stopAndReap(initialSignal: SIGTERM)
        throw error
    }
}

private func exitLikeChild(_ status: Int32) -> Never {
    let terminatingSignal = status & 0x7f
    if terminatingSignal == 0 {
        _exit((status >> 8) & 0xff)
    }

    _ = signal(terminatingSignal, SIG_DFL)
    var signalSet = sigset_t()
    sigemptyset(&signalSet)
    sigaddset(&signalSet, terminatingSignal)
    _ = pthread_sigmask(SIG_UNBLOCK, &signalSet, nil)
    _ = kill(getpid(), terminatingSignal)
    _exit(128 + terminatingSignal)
}

let probeArguments = Array(CommandLine.arguments.dropFirst())
if probeArguments.first == "--bootstrap-child" {
    do {
        try runBootstrapChild(probeArguments)
    } catch {
        _exit(70)
    }
} else {
    var readinessWasPublished = false
    do {
        switch try runProbe(readinessPublished: {
            readinessWasPublished = true
        }) {
        case let .child(status):
            exitLikeChild(status)
        case .endOfInput:
            _exit(0)
        case let .externalSignal(signal):
            exitLikeChild(signal)
        }
    } catch PtyProbeError.invalidArguments {
        try? writeAll(Array("pty-client-probe: invalid arguments\n".utf8), to: STDERR_FILENO)
        _exit(64)
    } catch {
        if !readinessWasPublished {
            try? writeAll(Array("pty-client-probe: operation failed\n".utf8), to: STDERR_FILENO)
        }
        _exit(70)
    }
}
