import Foundation
import XCTest
@testable import TokenStepSwift

final class NetworkSupplyChainPolicyTests: XCTestCase {
    func testEphemeralConfigurationDisablesPersistentHTTPState() {
        let configuration = BoundedNetworkPolicy.ephemeralConfiguration(
            requestTimeout: 7,
            resourceTimeout: 11
        )

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 7)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 11)
    }

    func testOversizedContentLengthIsRejectedBeforeBody() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://updates.example/manifest.json")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "5"]
            )
        )

        XCTAssertThrowsError(
            try BoundedNetworkPolicy.validateResponse(response, maximumBytes: 4)
        ) { error in
            XCTAssertEqual(error as? BoundedNetworkError, .responseTooLarge)
        }
    }

    func testInsecureFinalResponseURLIsRejected() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://team.example/api/v1/devices/enroll")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "2"]
            )
        )

        XCTAssertThrowsError(
            try BoundedNetworkPolicy.validateResponse(response, maximumBytes: 4)
        ) { error in
            XCTAssertEqual(error as? BoundedNetworkError, .insecureURL)
        }
    }

    func testChunkedBodyCannotCrossActualByteLimit() throws {
        var accumulator = BoundedBodyAccumulator(maximumBytes: 4)
        try accumulator.append(Data([0, 1, 2]))
        XCTAssertEqual(accumulator.data.count, 3)

        XCTAssertThrowsError(try accumulator.append(Data([3, 4]))) { error in
            XCTAssertEqual(error as? BoundedNetworkError, .bodyTooLarge)
        }
        XCTAssertEqual(accumulator.data.count, 3)
    }

    func testManifestAndLeaderboardRedirectsAreAlwaysRejected() {
        XCTAssertThrowsError(try BoundedNetworkPolicy.rejectRedirect()) { error in
            XCTAssertEqual(error as? BoundedNetworkError, .redirectRejected)
        }
    }

    func testDMGDeclaredSizeMustBePositiveAndWithinOneGiB() {
        XCTAssertThrowsError(try UpdateNetworkPolicy.validateDeclaredAssetSize(0))
        XCTAssertThrowsError(try UpdateNetworkPolicy.validateDeclaredAssetSize(-1))
        XCTAssertThrowsError(
            try UpdateNetworkPolicy.validateDeclaredAssetSize(
                Int(UpdateNetworkPolicy.maximumDMGBytes + 1)
            )
        )
        XCTAssertEqual(
            try UpdateNetworkPolicy.validateDeclaredAssetSize(
                Int(UpdateNetworkPolicy.maximumDMGBytes)
            ),
            UpdateNetworkPolicy.maximumDMGBytes
        )
    }

    func testDMGAllowsThreeCrossHostHTTPSRedirectsButRejectsFourth() throws {
        let github = URL(string: "https://github.com/org/repo/releases/download/v1/app.dmg")!
        let objects = URL(string: "https://objects.githubusercontent.com/release-assets/app.dmg")!

        var count = try UpdateNetworkPolicy.validatedRedirectCount(
            from: github,
            to: objects,
            currentCount: 0
        )
        count = try UpdateNetworkPolicy.validatedRedirectCount(
            from: objects,
            to: github,
            currentCount: count
        )
        count = try UpdateNetworkPolicy.validatedRedirectCount(
            from: github,
            to: objects,
            currentCount: count
        )
        XCTAssertEqual(count, 3)
        XCTAssertThrowsError(
            try UpdateNetworkPolicy.validatedRedirectCount(
                from: objects,
                to: github,
                currentCount: count
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadPolicyError, .tooManyRedirects)
        }
    }

    func testDMGRedirectRejectsAnyInsecureHop() {
        let secure = URL(string: "https://github.com/release.dmg")!
        let insecure = URL(string: "http://objects.githubusercontent.com/release.dmg")!

        XCTAssertThrowsError(
            try UpdateNetworkPolicy.validatedRedirectCount(
                from: secure,
                to: insecure,
                currentCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadPolicyError, .insecureURL)
        }
        XCTAssertThrowsError(
            try UpdateNetworkPolicy.validatedRedirectCount(
                from: insecure,
                to: secure,
                currentCount: 0
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadPolicyError, .insecureURL)
        }
    }

    func testDMGContentLengthMustMatchManifestAndHardLimit() throws {
        let mismatch = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://objects.githubusercontent.com/release.dmg")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "4"]
            )
        )
        XCTAssertThrowsError(
            try UpdateNetworkPolicy.validateDownloadResponse(
                mismatch,
                declaredAssetSize: 5
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadPolicyError, .contentLengthMismatch)
        }

        let oversized = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://objects.githubusercontent.com/release.dmg")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": "\(UpdateNetworkPolicy.maximumDMGBytes + 1)"
                ]
            )
        )
        XCTAssertThrowsError(
            try UpdateNetworkPolicy.validateDownloadResponse(
                oversized,
                declaredAssetSize: UpdateNetworkPolicy.maximumDMGBytes
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadPolicyError, .responseTooLarge)
        }
    }

    func testDMGUnknownContentLengthStillEnforcesActualBytes() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://objects.githubusercontent.com/release.dmg")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        XCTAssertNil(
            try UpdateNetworkPolicy.validateDownloadResponse(
                response,
                declaredAssetSize: 4
            )
        )
        XCTAssertEqual(
            try UpdateNetworkPolicy.validatedCumulativeBytes(
                currentBytes: 3,
                nextChunkBytes: 1,
                declaredAssetSize: 4
            ),
            4
        )
        XCTAssertThrowsError(
            try UpdateNetworkPolicy.validatedCumulativeBytes(
                currentBytes: 3,
                nextChunkBytes: 2,
                declaredAssetSize: 4
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadPolicyError, .bodyTooLarge)
        }
    }

    func testFinalSizeMismatchDeletesOwnedTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenfleet-network-policy-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("download.dmg")
        try Data([0, 1, 2]).write(to: fileURL)

        XCTAssertThrowsError(
            try UpdateDownloadedFileValidator.validateOrRemove(
                fileURL,
                declaredAssetSize: 4
            )
        ) { error in
            XCTAssertEqual(error as? UpdateDownloadPolicyError, .finalSizeMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testReleaseManifestRejectsInvalidDMGSize() throws {
        let manifest = """
        {
          "tag_name": "v9.0.0",
          "name": "TokenFleet 9.0.0",
          "body": "",
          "draft": false,
          "prerelease": false,
          "html_url": "https://github.com/example/tokenfleet/releases/tag/v9.0.0",
          "assets": [{
            "name": "TokenFleet-9.0.0.dmg",
            "browser_download_url": "https://github.com/example/tokenfleet/releases/download/v9.0.0/TokenFleet.dmg",
            "size": 0
          }]
        }
        """

        XCTAssertThrowsError(
            try UpdateService.updateResult(
                fromManifestData: Data(manifest.utf8),
                currentVersion: "1.0.0"
            )
        ) { error in
            guard case UpdateError.missingDMG = error else {
                XCTFail("Expected missingDMG, got \(error)")
                return
            }
        }
    }
}
