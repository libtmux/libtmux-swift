package enum ProcessExecutable: Sendable, Equatable {
    case name(String)
    case path(String)
}

package enum OutputPolicy: Sendable, Equatable {
    case complete
    case limited(maxBytesPerStream: Int)
}

package enum ProcessRequestError: Error, Sendable, Equatable {
    case nonPositiveOutputLimit(Int)
}

package struct ProcessRequest: Sendable, Equatable {
    package let executable: ProcessExecutable
    package let arguments: [String]
    package let environment: [String: String]
    package let workingDirectory: String?
    package let outputPolicy: OutputPolicy

    package init(
        executable: ProcessExecutable,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        outputPolicy: OutputPolicy
    ) throws {
        if case let .limited(maxBytesPerStream) = outputPolicy,
            maxBytesPerStream <= 0
        {
            throw ProcessRequestError.nonPositiveOutputLimit(maxBytesPerStream)
        }

        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.outputPolicy = outputPolicy
    }
}

package enum ProcessTermination: Sendable, Equatable {
    case exited(Int32)
    case unhandledSignal(Int32)
}

package struct ProcessReply: Sendable, Equatable {
    package let standardOutput: [UInt8]
    package let standardError: [UInt8]
    package let termination: ProcessTermination

    package init(
        standardOutput: [UInt8],
        standardError: [UInt8],
        termination: ProcessTermination
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.termination = termination
    }
}

package protocol ProcessTransport: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessReply
}
