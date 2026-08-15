import Foundation
import XCTest

@testable import SpikeSupport

final class IdentityPrimitiveTests: XCTestCase {
    func testSocketNameAndSocketPathAreMutuallyExclusiveIncarnations() throws {
        let token = UUID(uuidString: "A4C9948B-961B-4218-9A3F-1E6998E208DB")!
        let namedServer = try ServerIncarnationID(
            endpoint: .socketName("libtmux"),
            token: token
        )
        let pathServer = try ServerIncarnationID(
            endpoint: .socketPath("/tmp/libtmux.sock"),
            token: token
        )

        XCTAssertNotEqual(namedServer.endpoint, pathServer.endpoint)
        XCTAssertNotEqual(namedServer, pathServer)
    }

    func testIncarnationRejectsEmptyEndpointValues() {
        let token = UUID(uuidString: "A4C9948B-961B-4218-9A3F-1E6998E208DB")!

        XCTAssertThrowsError(
            try ServerIncarnationID(endpoint: .socketName(""), token: token)
        ) { error in
            XCTAssertEqual(error as? TmuxEndpointError, .emptyEndpoint)
        }
    }
}
