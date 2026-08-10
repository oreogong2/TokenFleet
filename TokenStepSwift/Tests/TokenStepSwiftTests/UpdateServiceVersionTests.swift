import XCTest
@testable import TokenStepSwift

final class UpdateServiceVersionTests: XCTestCase {
    func testStableReleaseIsNewerThanMatchingPrerelease() {
        XCTAssertLessThan(Version("0.1.0-beta.1"), Version("0.1.0"))
    }

    func testPrereleaseIdentifiersFollowSemanticVersionOrder() {
        XCTAssertLessThan(Version("0.1.0-beta.1"), Version("0.1.0-beta.2"))
        XCTAssertLessThan(Version("0.1.0-beta.2"), Version("0.1.0-beta.3"))
        XCTAssertLessThan(Version("0.1.0-beta.3"), Version("0.1.0-beta.4"))
        XCTAssertLessThan(Version("0.1.0-beta.4"), Version("0.1.0-beta.5"))
        XCTAssertLessThan(Version("0.1.0-beta.5"), Version("0.1.0-rc.1"))
    }

    func testBuildMetadataDoesNotChangePrecedence() {
        XCTAssertEqual(Version("v1.2.3+build.7"), Version("1.2.3+build.9"))
    }
}
