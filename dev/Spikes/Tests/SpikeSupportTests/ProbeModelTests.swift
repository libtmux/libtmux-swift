import XCTest

@testable import SpikeSupport

final class ProbeModelTests: XCTestCase {
    func testRequestPreservesArgumentBoundariesAndReplyRepresentsExitStatus() throws {
        let request = try ProcessRequest(
            executable: .path("/usr/bin/printf"),
            arguments: [
                "value with spaces",
                "\"quoted\"",
                "semi;colon",
                "$dollar",
                "line\nbreak",
            ],
            environment: ["LANG": "C"],
            workingDirectory: nil,
            outputPolicy: .limited(maxBytesPerStream: 4096)
        )

        XCTAssertEqual(
            request,
            try ProcessRequest(
                executable: .path("/usr/bin/printf"),
                arguments: [
                    "value with spaces",
                    "\"quoted\"",
                    "semi;colon",
                    "$dollar",
                    "line\nbreak",
                ],
                environment: ["LANG": "C"],
                workingDirectory: nil,
                outputPolicy: .limited(maxBytesPerStream: 4096)
            )
        )

        let reply = ProcessReply(
            standardOutput: [0, 255],
            standardError: [10],
            termination: .exited(23)
        )

        XCTAssertEqual(reply.standardOutput, [0, 255])
        XCTAssertEqual(reply.standardError, [10])
        XCTAssertEqual(reply.termination, .exited(23))
    }

    func testRequestRejectsNonPositiveExplicitOutputLimits() {
        XCTAssertThrowsError(
            try ProcessRequest(
                executable: .name("echo"),
                arguments: [],
                environment: [:],
                workingDirectory: nil,
                outputPolicy: .limited(maxBytesPerStream: 0)
            )
        ) { error in
            XCTAssertEqual(error as? ProcessRequestError, .nonPositiveOutputLimit(0))
        }
    }
}
