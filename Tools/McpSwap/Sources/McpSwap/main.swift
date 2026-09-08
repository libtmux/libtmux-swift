import McpSwapCore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

exit(CommandRunner.run())
