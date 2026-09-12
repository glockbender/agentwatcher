import Darwin
import XCTest

@testable import AgentWatchCore

final class PosixSocketTests: XCTestCase {
    func testDarwinAddressLeavesRoomForTheTerminator() throws {
        var address = try XCTUnwrap(PosixSocket.makeAddress(path: String(repeating: "a", count: 103)))
        XCTAssertEqual(MemoryLayout.size(ofValue: address.sun_path), 104)
        withUnsafeBytes(of: &address.sun_path) { bytes in
            XCTAssertEqual(bytes[102], 0x61)
            XCTAssertEqual(bytes[103], 0)
        }
        XCTAssertNil(PosixSocket.makeAddress(path: String(repeating: "a", count: 104)))
        XCTAssertNil(PosixSocket.makeAddress(path: String(repeating: "a", count: 105)))
    }

    func testTheLimitCountsUTF8BytesAndRejectsEmbeddedTerminators() {
        XCTAssertNotNil(PosixSocket.makeAddress(path: String(repeating: "é", count: 51) + "a"))
        XCTAssertNil(PosixSocket.makeAddress(path: String(repeating: "é", count: 52)))
        XCTAssertNil(PosixSocket.makeAddress(path: "/tmp/one\0two"))
        XCTAssertNil(PosixSocket.makeAddress(path: ""))
    }
}
