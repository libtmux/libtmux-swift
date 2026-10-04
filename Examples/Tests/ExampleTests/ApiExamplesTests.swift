import Foundation
import Testing

private struct ApiExampleManifest: Decodable {
    let schemaVersion: Int
    let packageFile: String
    let examples: [ApiExample]
}

private struct ApiExample: Decodable {
    let name: String
    let file: String
    let symbols: [String]
    let expectedOutput: [String]
}

@Suite("complete API programs", .timeLimit(.minutes(5)))
struct ApiExamplesTests {
    @Test("the complete entry points print their documented results")
    func completePrograms() async throws {
        let examples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repository = examples.deletingLastPathComponent()
        let file = examples.appendingPathComponent("api-examples.json")
        let manifest = try JSONDecoder().decode(
            ApiExampleManifest.self,
            from: Data(contentsOf: file)
        )
        #expect(manifest.schemaVersion == 1)
        try #require(!manifest.examples.isEmpty)
        #expect(
            Set(manifest.examples.map(\.name)).count == manifest.examples.count)
        #expect(
            FileManager.default.fileExists(
                atPath:
                    repository
                    .appendingPathComponent(manifest.packageFile).path))

        for example in manifest.examples {
            try #require(!example.symbols.isEmpty)
            try #require(!example.expectedOutput.isEmpty)
            let source = repository.appendingPathComponent(example.file)
            try #require(FileManager.default.fileExists(atPath: source.path))
            let process = Process()
            process.executableURL = examples.appendingPathComponent(
                ".build/debug/\(example.name)")
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            while process.isRunning && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(
                !process.isRunning, "\(example.name) exceeded 30 seconds")
            let printed = String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            #expect(process.terminationStatus == 0, "\(example.name) failed")
            #expect(
                printed == example.expectedOutput.joined(separator: "\n")
                    + "\n",
                "\(example.name) printed a different result")
        }
    }
}
