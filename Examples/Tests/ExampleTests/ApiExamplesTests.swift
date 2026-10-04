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
        let manifest = try JSONDecoder().decode(
            ApiExampleManifest.self,
            from: Data(contentsOf: examples.appendingPathComponent("api-examples.json"))
        )
        #expect(manifest.schemaVersion == 1)
        try #require(!manifest.examples.isEmpty)
        #expect(Set(manifest.examples.map(\.name)).count == manifest.examples.count)
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
            process.executableURL = examples.appendingPathComponent(".build/debug/\(example.name)")
            let result: ProgramResult
            do {
                result = try await runProgram(process, within: .seconds(120))
            } catch is ProgramTimedOut {
                Issue.record("\(example.name) exceeded 120 seconds")
                continue
            }
            let printed = result.output
            #expect(result.status == 0, "\(example.name) failed")
            #expect(
                printed == example.expectedOutput.joined(separator: "\n") + "\n",
                "\(example.name) printed a different result")
        }
    }
}
