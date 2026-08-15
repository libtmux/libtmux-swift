package struct InteractiveProcessRequest: Sendable, Equatable {
    package let executable: ProcessExecutable
    package let arguments: [String]
    package let environment: [String: String]
    package let workingDirectory: String?

    package init(
        executable: ProcessExecutable,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

package protocol InteractiveProcessSession: Sendable {
    var standardOutput: AsyncThrowingStream<[UInt8], any Error> { get }
    var standardError: AsyncThrowingStream<[UInt8], any Error> { get }

    func writeStandardInput(_ bytes: [UInt8]) async throws
    func finishStandardInput() async throws
    func terminate() async throws
    func waitForTermination() async throws -> ProcessTermination
}

package protocol InteractiveProcessLauncher: Sendable {
    func launch(
        _ request: InteractiveProcessRequest
    ) async throws -> any InteractiveProcessSession
}
