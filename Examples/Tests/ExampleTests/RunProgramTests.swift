import Foundation
import Testing

@Suite("running a child program", .timeLimit(.minutes(5)))
struct RunProgramTests {
    @Test("a program that exits returns what it printed and its status")
    func exitingProgramReturnsItsOutput() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'hello\\n'; exit 3"]

        let result = try await runProgram(process)

        #expect(result.output == "hello\n")
        #expect(result.status == 3)
    }

    @Test("a program that does not exit is stopped at the limit")
    func runningProgramIsStoppedAtTheLimit() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30"]

        await #expect(throws: ProgramTimedOut.self) {
            try await runProgram(process, within: .milliseconds(300))
        }
    }
}
