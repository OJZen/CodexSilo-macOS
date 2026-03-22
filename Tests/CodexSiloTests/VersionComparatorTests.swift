import XCTest
@testable import CodexSilo

final class VersionComparatorTests: XCTestCase {
    func testIsNewer() {
        XCTAssertTrue(VersionComparator.isNewer(latest: "0.6.0", current: "0.5.9"))
        XCTAssertFalse(VersionComparator.isNewer(latest: "0.6.0", current: "0.6.0"))
        XCTAssertFalse(VersionComparator.isNewer(latest: "0.5.9", current: "0.6.0"))
        XCTAssertTrue(VersionComparator.isNewer(latest: "1.0.0-beta.2", current: "1.0.0-beta.1"))
    }
}
