// The examples in <doc:PlatformSupport>.

import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public func branchOnTheReleaseTheServerRuns(_ server: Server) async throws -> TmuxVersion {
    if try await server.version() < TmuxVersion(major: 3, minor: 4) {
        print("this release predates the behaviour relied on below")
    }
    return try await server.version()
}

// Compiled, never executed: the disposition is process-global, and the test
// runner has already chosen it. Asserting on it here would assert on the
// harness rather than on the example.
public func decideWhatABrokenPipeMeans() {
    signal(SIGPIPE, SIG_IGN)
}
