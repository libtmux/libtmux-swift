import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum ProbeError: Error {
    case invalidArguments
    case invalidHex
    case readFailure(Int32)
    case writeFailure(Int32)
}

func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = write(
                descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                throw ProbeError.writeFailure(errno)
            }
        }
    }
}

func lengthPrefixed(_ bytes: [UInt8]) -> [UInt8] {
    withUnsafeBytes(of: UInt64(bytes.count).bigEndian, Array.init) + bytes
}

func bytes(fromHex value: String) throws -> [UInt8] {
    guard value.count.isMultiple(of: 2) else { throw ProbeError.invalidHex }
    var bytes: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
        let end = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<end], radix: 16) else {
            throw ProbeError.invalidHex
        }
        bytes.append(byte)
        index = end
    }
    return bytes
}

func reportProcessIdentifier(marker: String?, descendant: Int32? = nil) throws {
    let bytes = Array("\(getpid())\n".utf8)
    try writeAll(bytes, to: STDOUT_FILENO)
    try writeProcessMarker(marker, descendant: descendant)
}

func terminateAndReap(_ processIdentifier: Int32) {
    _ = kill(processIdentifier, SIGKILL)
    while waitpid(processIdentifier, nil, 0) < 0, errno == EINTR {}
}

func writeProcessMarker(_ marker: String?, descendant: Int32? = nil) throws {
    if let marker, marker != "-" {
        let record = Array("\(getpid()) \(descendant ?? 0) \(getpgrp())\n".utf8)
        try Data(record).write(to: URL(fileURLWithPath: marker), options: .atomic)
    }
}

func spawnSilentDescendant(
    ignoreTermination: Bool = false,
    beforeRelease: (Int32) throws -> Void
) throws -> Int32 {
    var releaseDescriptors: [Int32] = [0, 0]
    guard pipe(&releaseDescriptors) == 0 else { throw ProbeError.invalidArguments }
    var readinessDescriptors: [Int32] = [0, 0]
    guard pipe(&readinessDescriptors) == 0 else {
        close(releaseDescriptors[0])
        close(releaseDescriptors[1])
        throw ProbeError.invalidArguments
    }
    let processIdentifier = fork()
    guard processIdentifier >= 0 else {
        close(releaseDescriptors[0])
        close(releaseDescriptors[1])
        close(readinessDescriptors[0])
        close(readinessDescriptors[1])
        throw ProbeError.invalidArguments
    }
    if processIdentifier == 0 {
        close(releaseDescriptors[1])
        close(readinessDescriptors[0])
        if ignoreTermination {
            _ = signal(SIGTERM, SIG_IGN)
        }
        do {
            try writeAll([1], to: readinessDescriptors[1])
        } catch {
            _exit(0)
        }
        close(readinessDescriptors[1])
        var release: UInt8 = 0
        var count: Int
        repeat {
            count = read(releaseDescriptors[0], &release, 1)
        } while count < 0 && errno == EINTR
        close(releaseDescriptors[0])
        guard count == 1, release == 1 else { _exit(0) }
        close(STDIN_FILENO)
        close(STDOUT_FILENO)
        close(STDERR_FILENO)
        while true { pause() }
    }
    close(releaseDescriptors[0])
    close(readinessDescriptors[1])
    var ready: UInt8 = 0
    var readinessCount: Int
    repeat {
        readinessCount = read(readinessDescriptors[0], &ready, 1)
    } while readinessCount < 0 && errno == EINTR
    close(readinessDescriptors[0])
    guard readinessCount == 1, ready == 1 else {
        close(releaseDescriptors[1])
        terminateAndReap(processIdentifier)
        throw ProbeError.invalidArguments
    }
    do {
        try beforeRelease(processIdentifier)
        try writeAll([1], to: releaseDescriptors[1])
        close(releaseDescriptors[1])
        return processIdentifier
    } catch {
        close(releaseDescriptors[1])
        terminateAndReap(processIdentifier)
        throw error
    }
}

func runFramedEcho() throws {
    var buffered: [UInt8] = []
    var scratch = [UInt8](repeating: 0, count: 997)
    while true {
        let count = read(STDIN_FILENO, &scratch, scratch.count)
        if count > 0 {
            buffered.append(contentsOf: scratch[..<count])
            while buffered.count >= 4 {
                let length = buffered.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let frameLength = 4 + Int(length)
                guard buffered.count >= frameLength else { break }
                let frame = Array(buffered[..<frameLength])
                buffered.removeFirst(frameLength)
                try writeAll(frame, to: STDOUT_FILENO)
                try writeAll(frame, to: STDERR_FILENO)
            }
        } else if count == 0 {
            guard buffered.isEmpty else { throw ProbeError.invalidArguments }
            return
        } else if errno != EINTR {
            throw ProbeError.readFailure(errno)
        }
    }
}

func run() throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first else { throw ProbeError.invalidArguments }
    switch mode {
    case "argv":
        for argument in arguments.dropFirst() {
            try writeAll(lengthPrefixed(Array(argument.utf8)), to: STDOUT_FILENO)
        }
        return 0
    case "argv-marker", "argv-marker-stdin":
        guard arguments.count >= 2 else { throw ProbeError.invalidArguments }
        if mode == "argv-marker-stdin" {
            guard fcntl(STDIN_FILENO, F_GETFD) >= 0 else { throw ProbeError.invalidArguments }
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 0 else { throw ProbeError.invalidArguments }
        }
        try writeProcessMarker(arguments[1])
        for argument in arguments.dropFirst(2) {
            try writeAll(lengthPrefixed(Array(argument.utf8)), to: STDOUT_FILENO)
        }
        return 0
    case "context":
        let directory = FileManager.default.currentDirectoryPath
        try writeAll(lengthPrefixed(Array(directory.utf8)), to: STDOUT_FILENO)
        for key in arguments.dropFirst() {
            try writeAll(
                lengthPrefixed(Array((ProcessInfo.processInfo.environment[key] ?? "").utf8)),
                to: STDOUT_FILENO
            )
        }
        return 0
    case "alternate":
        guard arguments.count == 3, let count = Int(arguments[1]),
            let size = Int(arguments[2]), count >= 0, size >= 0
        else { throw ProbeError.invalidArguments }
        let output = [UInt8](repeating: 0x41, count: size)
        let error = [UInt8](repeating: 0x42, count: size)
        for _ in 0..<count {
            try writeAll(output, to: STDOUT_FILENO)
            try writeAll(error, to: STDERR_FILENO)
        }
        return 0
    case "invalid":
        guard arguments.count == 3 else { throw ProbeError.invalidArguments }
        try writeAll(try bytes(fromHex: arguments[1]), to: STDOUT_FILENO)
        try writeAll(try bytes(fromHex: arguments[2]), to: STDERR_FILENO)
        return 0
    case "finite-stream":
        guard arguments.count == 3, let count = Int(arguments[2]), count >= 0 else {
            throw ProbeError.invalidArguments
        }
        let descriptor: Int32
        let byte: UInt8
        if arguments[1] == "stdout" {
            descriptor = STDOUT_FILENO
            byte = 0x45
        } else if arguments[1] == "stderr" {
            descriptor = STDERR_FILENO
            byte = 0x46
        } else {
            throw ProbeError.invalidArguments
        }
        try writeAll([UInt8](repeating: byte, count: count), to: descriptor)
        return 0
    case "pid":
        try reportProcessIdentifier(marker: nil)
        return 0
    case "delayed-exit":
        guard arguments.count == 2, let milliseconds = Double(arguments[1]), milliseconds >= 0
        else {
            throw ProbeError.invalidArguments
        }
        Thread.sleep(forTimeInterval: milliseconds / 1_000)
        return 0
    case "block":
        guard arguments.count == 2 else { throw ProbeError.invalidArguments }
        _ = try spawnSilentDescendant { descendant in
            try reportProcessIdentifier(marker: arguments[1], descendant: descendant)
        }
        while true { pause() }
    case "block-stubborn-descendant":
        guard arguments.count == 2 else { throw ProbeError.invalidArguments }
        _ = try spawnSilentDescendant(ignoreTermination: true) { descendant in
            try reportProcessIdentifier(marker: arguments[1], descendant: descendant)
        }
        while true { pause() }
    case "block-input-after-byte":
        guard arguments.count == 3 else { throw ProbeError.invalidArguments }
        let descendant = try spawnSilentDescendant { descendant in
            try reportProcessIdentifier(marker: arguments[1], descendant: descendant)
        }
        var byte: UInt8 = 0
        var count: Int
        repeat {
            count = read(STDIN_FILENO, &byte, 1)
        } while count < 0 && errno == EINTR
        guard count == 1 else { throw ProbeError.readFailure(errno) }
        try writeProcessMarker(arguments[2], descendant: descendant)
        while true { pause() }
    case "pre-marker-block":
        guard arguments.count == 2 else { throw ProbeError.invalidArguments }
        _ = try spawnSilentDescendant { _ in
            while true { pause() }
        }
        return 70
    case "marker-write-failure":
        guard arguments.count == 3 else { throw ProbeError.invalidArguments }
        _ = try spawnSilentDescendant { descendant in
            try writeProcessMarker(arguments[1], descendant: descendant)
            try reportProcessIdentifier(marker: arguments[2], descendant: descendant)
        }
        return 0
    case "stream":
        guard arguments.count == 3, let size = Int(arguments[2]), size > 0 else {
            throw ProbeError.invalidArguments
        }
        _ = try spawnSilentDescendant { descendant in
            try reportProcessIdentifier(marker: arguments[1], descendant: descendant)
        }
        let output = [UInt8](repeating: 0x43, count: size)
        let error = [UInt8](repeating: 0x44, count: size)
        while true {
            try writeAll(output, to: STDOUT_FILENO)
            try writeAll(error, to: STDERR_FILENO)
        }
    case "limit-stdout", "limit-stderr":
        guard arguments.count == 3, let size = Int(arguments[2]), size > 0 else {
            throw ProbeError.invalidArguments
        }
        _ = try spawnSilentDescendant { descendant in
            try reportProcessIdentifier(marker: arguments[1], descendant: descendant)
        }
        let bytes = [UInt8](repeating: mode == "limit-stdout" ? 0x45 : 0x46, count: size)
        let descriptor = mode == "limit-stdout" ? STDOUT_FILENO : STDERR_FILENO
        while true { try writeAll(bytes, to: descriptor) }
    case "limit-stubborn-descendant":
        guard arguments.count == 3, let size = Int(arguments[2]), size > 0 else {
            throw ProbeError.invalidArguments
        }
        _ = try spawnSilentDescendant(ignoreTermination: true) { descendant in
            try reportProcessIdentifier(marker: arguments[1], descendant: descendant)
        }
        let bytes = [UInt8](repeating: 0x45, count: size)
        while true { try writeAll(bytes, to: STDOUT_FILENO) }
    case "limit-stderr-first":
        guard arguments.count == 3, let size = Int(arguments[2]), size > 0 else {
            throw ProbeError.invalidArguments
        }
        _ = try spawnSilentDescendant { descendant in
            try reportProcessIdentifier(marker: arguments[1], descendant: descendant)
        }
        let error = [UInt8](repeating: 0x47, count: size)
        let output = [UInt8](repeating: 0x48, count: size)
        try writeAll(error, to: STDERR_FILENO)
        while true {
            try writeAll(output, to: STDOUT_FILENO)
            try writeAll(error, to: STDERR_FILENO)
        }
    case "framed-echo":
        try runFramedEcho()
        return 0
    case "close-input", "delayed-close-input", "close-input-stubborn-descendant":
        guard arguments.count == 2 else { throw ProbeError.invalidArguments }
        close(STDIN_FILENO)
        if mode == "close-input-stubborn-descendant" {
            _ = try spawnSilentDescendant(ignoreTermination: true) { descendant in
                try reportProcessIdentifier(marker: arguments[1], descendant: descendant)
            }
        } else if mode == "delayed-close-input" {
            try writeAll(Array("\(getpid())\n".utf8), to: STDOUT_FILENO)
            Thread.sleep(forTimeInterval: 0.5)
            try writeProcessMarker(arguments[1])
        } else {
            try reportProcessIdentifier(marker: arguments[1])
        }
        while true { pause() }
    case "close-output-block":
        guard arguments.count == 2 else { throw ProbeError.invalidArguments }
        _ = try spawnSilentDescendant { descendant in
            try reportProcessIdentifier(marker: arguments[1], descendant: descendant)
        }
        close(STDOUT_FILENO)
        close(STDERR_FILENO)
        while true { pause() }
    case "signal":
        guard arguments.count == 2, let signalNumber = Int32(arguments[1]) else {
            throw ProbeError.invalidArguments
        }
        var signalSet = sigset_t()
        sigemptyset(&signalSet)
        sigaddset(&signalSet, signalNumber)
        pthread_sigmask(SIG_UNBLOCK, &signalSet, nil)
        _ = signal(signalNumber, SIG_DFL)
        _ = raise(signalNumber)
        return 127
    case "signal-mask-membership":
        guard arguments.count == 2, let signalNumber = Int32(arguments[1]) else {
            throw ProbeError.invalidArguments
        }
        var signalSet = sigset_t()
        guard pthread_sigmask(SIG_SETMASK, nil, &signalSet) == 0 else {
            throw ProbeError.invalidArguments
        }
        let membership = sigismember(&signalSet, signalNumber)
        guard membership == 0 || membership == 1 else {
            throw ProbeError.invalidArguments
        }
        try writeAll(Array("\(membership)\n".utf8), to: STDOUT_FILENO)
        return 0
    case "raise-inherited-signal":
        guard arguments.count == 3, let signalNumber = Int32(arguments[1]) else {
            throw ProbeError.invalidArguments
        }
        try writeProcessMarker(arguments[2])
        _ = raise(signalNumber)
        return 127
    case "exit":
        guard arguments.count == 2, let status = Int32(arguments[1]) else {
            throw ProbeError.invalidArguments
        }
        return status
    case "exit-marker":
        guard arguments.count == 3, let status = Int32(arguments[2]) else {
            throw ProbeError.invalidArguments
        }
        try reportProcessIdentifier(marker: arguments[1])
        return status
    default:
        throw ProbeError.invalidArguments
    }
}

do {
    exit(try run())
} catch {
    try? writeAll(Array("process-probe: \(error)\n".utf8), to: STDERR_FILENO)
    exit(64)
}
