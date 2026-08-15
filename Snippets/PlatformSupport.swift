// The examples in <doc:PlatformSupport>.

import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

func branchOnTheReleaseTheServerRuns(_ server: Server) async throws {
    if try await server.version() < TmuxVersion(major: 3, minor: 4) {
        print("this release predates the behaviour relied on below")
    }
}

func decideWhatABrokenPipeMeans() {
    signal(SIGPIPE, SIG_IGN)
}
