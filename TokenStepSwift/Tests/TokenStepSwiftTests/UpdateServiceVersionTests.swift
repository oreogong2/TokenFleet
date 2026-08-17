import Foundation
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
        XCTAssertLessThan(Version("0.1.0-beta.5"), Version("0.1.0-beta.6"))
        XCTAssertLessThan(Version("0.1.0-beta.6"), Version("0.1.0-beta.7"))
        XCTAssertLessThan(Version("0.1.0-beta.7"), Version("0.1.0-rc.1"))
    }

    func testBuildMetadataDoesNotChangePrecedence() {
        XCTAssertEqual(Version("v1.2.3+build.7"), Version("1.2.3+build.9"))
    }

    func testBetaInstallAcceptsNewerPrereleaseManifest() throws {
        let result = try UpdateService.updateResult(
            fromManifestData: releaseManifest(version: "0.1.0-beta.8", prerelease: true),
            currentVersion: "0.1.0-beta.7"
        )
        guard case let .available(update) = result else {
            XCTFail("Expected beta.8 to be available to beta.7")
            return
        }
        XCTAssertEqual(update.version, "0.1.0-beta.8")
    }

    func testStableInstallDoesNotEnterPrereleaseChannel() throws {
        let result = try UpdateService.updateResult(
            fromManifestData: releaseManifest(version: "0.2.0-beta.1", prerelease: true),
            currentVersion: "0.1.0"
        )
        guard case .upToDate = result else {
            XCTFail("A stable install must ignore prerelease manifests")
            return
        }
    }

    private func releaseManifest(version: String, prerelease: Bool) -> Data {
        Data(
            """
            {
              "tag_name": "v\(version)",
              "name": "TokenFleet \(version)",
              "body": "",
              "draft": false,
              "prerelease": \(prerelease),
              "html_url": "https://github.com/oreogong2/TokenFleet/releases/tag/v\(version)",
              "assets": [{
                "name": "TokenFleet-\(version).dmg",
                "browser_download_url": "https://github.com/oreogong2/TokenFleet/releases/download/v\(version)/TokenFleet-\(version).dmg",
                "size": 1024
              }]
            }
            """.utf8
        )
    }
}
