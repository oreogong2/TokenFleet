import CryptoKit
import Foundation
import XCTest
@testable import TokenStepSwift

final class TeamSyncProtocolTests: XCTestCase {
    func testTeamSyncHTTPResponsesAreCappedAtOneMiB() {
        XCTAssertEqual(
            TeamSyncProtocolConfiguration.maximumHTTPResponseBytes,
            1_048_576
        )
    }

    func testProductionCommunityServerOriginComesOnlyFromStrictBundleValue() throws {
        XCTAssertEqual(
            TeamSyncCommunityServerConfiguration.infoDictionaryKey,
            "TokenFleetCommunityServerURL"
        )
        let valid = try XCTUnwrap(
            TeamSyncCommunityServerConfiguration.validatedProductionOrigin(
                infoDictionaryValue: "https://community.example.com:8443"
            )
        )
        XCTAssertEqual(valid.absoluteString, "https://community.example.com:8443")
        XCTAssertTrue(
            TeamSyncCommunityServerConfiguration.persistedOrigin(
                "https://community.example.com:8443/",
                matches: valid
            )
        )
        XCTAssertFalse(
            TeamSyncCommunityServerConfiguration.persistedOrigin(
                "https://other.example.com:8443",
                matches: valid
            )
        )
        XCTAssertFalse(
            TeamSyncCommunityServerConfiguration.persistedOrigin(
                "https://community.example.com:8443?runtime=override",
                matches: valid
            )
        )

        let invalidValues: [Any?] = [
            nil,
            42,
            "",
            " https://community.example.com",
            "HTTPS://community.example.com",
            "https://COMMUNITY.example.com",
            "https://community.example.com/",
            "https://community.example.com:443",
            "http://community.example.com",
            "https://user:secret@community.example.com",
            "https://community.example.com/private",
            "https://community.example.com?override=1",
            "https://community.example.com#override",
            "https://community.example.com.",
            "https://localhost:8443",
            "https://127.0.0.1:8443",
            "https://127.0.0.2:8443",
            "https://127.1:8443",
            "https://2130706433:8443",
            "https://0x7f000001:8443",
            "https://[::1]:8443",
            "https://bad_host.example.com",
            "https://bücher.example.com"
        ]
        for value in invalidValues {
            XCTAssertNil(
                TeamSyncCommunityServerConfiguration.validatedProductionOrigin(
                    infoDictionaryValue: value
                ),
                "Unexpected production origin for \(String(describing: value))"
            )
        }
    }

    func testProductionCommunityOriginMatchesSharedContractFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/fixtures/community-origin-cases.tsv")
        let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
        var checked = 0
        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(
                separator: "\t",
                maxSplits: 2,
                omittingEmptySubsequences: false
            )
            XCTAssertEqual(fields.count, 3, "Malformed fixture line \(index + 1)")
            guard fields.count == 3, fields[0] == "production" else { continue }
            let rawValue = fields[2] == "<EMPTY>" ? "" : String(fields[2])
            let actual = TeamSyncCommunityServerConfiguration.validatedProductionOrigin(
                infoDictionaryValue: rawValue
            ) != nil
            XCTAssertEqual(
                actual,
                fields[1] == "valid",
                "Shared production origin fixture mismatch at line \(index + 1): \(fields[2])"
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
    }

    func testEnrollmentRequestMatchesContractAndHasNoAuthorizationHeader() throws {
        let request = try TeamSyncProtocol.enrollmentURLRequest(
            serverURL: "https://team.example.com/",
            enrollmentToken: "one-time-token",
            devicePublicID: "anonymous-uuid",
            appVersion: "0.1.45"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/devices/enroll")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["enrollment_token", "device_public_id", "platform", "app_version", "collector_version"]
        )
        XCTAssertEqual(object["enrollment_token"] as? String, "one-time-token")
        XCTAssertEqual(object["device_public_id"] as? String, "anonymous-uuid")
        XCTAssertEqual(object["platform"] as? String, "macos")
        XCTAssertEqual(object["collector_version"] as? String, "0.2.0")
    }

    func testCommunityRankRequestIsCredentialedGETWithoutQueryOrBody() throws {
        let request = try TeamSyncProtocol.communityRankURLRequest(
            serverURL: "https://team.example.com/",
            deviceID: "server-device-id",
            deviceSecret: "test-device-secret-00000000000000000000",
            timestamp: 1_786_240_000,
            nonce: "123e4567-e89b-12d3-a456-426614174000"
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/devices/me/community-rank")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Device-ID"),
            "server-device-id"
        )
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Signature"))
    }

    func testCommunityRankResponseValidatesIdentityAndRankBounds() throws {
        let data = Data(#"{"public_id":"123e4567-e89b-12d3-a456-426614174000","nickname":"奥哥","public_profile_enabled":true,"period":"today","metric":"tokens","rank":2,"total_entries":10,"metric_value":"704000000"}"#.utf8)
        let rank = try JSONDecoder().decode(TeamSyncCommunityRank.self, from: data)
        XCTAssertTrue(rank.isValid)
        XCTAssertEqual(rank.exceededPercentage, 80)

        var invalid = rank
        invalid.rank = 11
        XCTAssertFalse(invalid.isValid)
        invalid = rank
        invalid.publicProfileEnabled = false
        XCTAssertFalse(invalid.isValid)
        invalid = rank
        invalid.rank = nil
        XCTAssertFalse(invalid.isValid)
    }

    func testCrossPlatformGoldenHMACVector() {
        let body = Data(#"{"schema_version":1,"collector_version":"0.2.0","generated_at":"2026-08-09T01:30:00Z","buckets":[{"date":"2026-08-09","timezone":"Asia/Shanghai","tool":"Codex","model":"gpt-5","source":"local","input_tokens":120,"output_tokens":80,"cache_read_tokens":1000,"cache_write_tokens":50,"completeness":"exact"}]}"#.utf8)
        let bodyHash = Data(SHA256.hash(data: body)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(bodyHash, "3bfc3e7d12a7bbfdb5493d5914fbc656074527e523006653d55c071aa0019b38")

        let headers = TeamSyncProtocol.signedHeaders(
            deviceID: "server-device-id",
            deviceSecret: "test-device-secret-00000000000000000000",
            timestamp: 1_786_240_000,
            nonce: "123e4567-e89b-12d3-a456-426614174000",
            method: "POST",
            path: "/api/v1/usage/daily",
            body: body
        )

        XCTAssertEqual(headers.signature, "b6f61ec4a68f4693d1baa5115584db1cde917fbc80c376e8d6166af25334bb42")
        XCTAssertEqual(
            TeamSyncProtocol.canonical(
                timestamp: headers.timestamp,
                nonce: headers.nonce,
                method: "post",
                path: "/api/v1/usage/daily",
                body: body
            ),
            "1786240000\n123e4567-e89b-12d3-a456-426614174000\nPOST\n/api/v1/usage/daily\n3bfc3e7d12a7bbfdb5493d5914fbc656074527e523006653d55c071aa0019b38"
        )
    }

    func testDailyBucketsUseExactRowsAndSkipLegacyMarginals() throws {
        let snapshot = UsageSnapshot(
            generatedAt: nil,
            timezone: "Asia/Singapore",
            totals: UsageTotals(tokens: 1_250, cost: 0, activeDays: 2),
            daily: [
                DailyUsage(
                    date: "2026-08-08",
                    tools: ["Codex": 999],
                    models: ["gpt-5": 999],
                    atomicUsage: nil,
                    totalTokens: 999,
                    cost: 0
                ),
                DailyUsage(
                    date: "2026-08-09",
                    tools: ["Codex": 1_250],
                    models: ["gpt-5": 1_250],
                    atomicUsage: [
                        DailyAtomicUsage(
                            tool: "Codex",
                            model: "gpt-5",
                            inputTokens: 120,
                            outputTokens: 80,
                            cacheReadTokens: 1_000,
                            cacheWriteTokens: 50,
                            totalTokens: 1_250
                        )
                    ],
                    totalTokens: 1_250,
                    cost: 0
                )
            ],
            tools: [],
            models: [],
            sources: [:]
        )

        let build = try TeamSyncProtocol.dailyBucketBuild(snapshot: snapshot)
        let buckets = build.buckets

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.date, "2026-08-09")
        XCTAssertEqual(buckets.first?.timezone, "Asia/Singapore")
        XCTAssertEqual(buckets.first?.source, "local")
        XCTAssertEqual(buckets.first?.inputTokens, 120)
        XCTAssertEqual(buckets.first?.cacheReadTokens, 1_000)
        XCTAssertEqual(build.omittedIncompleteBucketCount, 1)
    }

    func testCompletenessOverwritesRatherThanChangingNaturalKey() throws {
        let exact = TeamSyncDailyBucket(
            date: "2026-08-09",
            timezone: "Asia/Shanghai",
            tool: "Codex",
            model: "gpt-5",
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 3,
            cacheWriteTokens: 4,
            completeness: "exact"
        )
        var estimate = exact
        estimate.completeness = "fallback_estimate"

        XCTAssertEqual(exact.naturalKey, estimate.naturalKey)
        XCTAssertNotEqual(
            try TeamSyncProtocol.contentHash(for: exact),
            try TeamSyncProtocol.contentHash(for: estimate)
        )
    }

    func testIncompleteAtomicBucketIsOmittedWithoutBlockingExactBucket() throws {
        let snapshot = UsageSnapshot(
            generatedAt: nil,
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 110, cost: 0, activeDays: 1),
            daily: [
                DailyUsage(
                    date: "2026-08-09",
                    tools: ["Codex": 110],
                    models: ["gpt-5": 10, "unknown": 100],
                    atomicUsage: [
                        DailyAtomicUsage(
                            tool: "Codex",
                            model: "gpt-5",
                            inputTokens: 1,
                            outputTokens: 2,
                            cacheReadTokens: 3,
                            cacheWriteTokens: 4,
                            totalTokens: 10
                        ),
                        DailyAtomicUsage(
                            tool: "Codex",
                            model: "unknown",
                            inputTokens: 0,
                            outputTokens: 0,
                            cacheReadTokens: 0,
                            cacheWriteTokens: 0,
                            totalTokens: 100,
                            breakdownComplete: false
                        )
                    ],
                    totalTokens: 110,
                    cost: 0
                )
            ],
            tools: [],
            models: [],
            sources: [:]
        )

        let build = try TeamSyncProtocol.dailyBucketBuild(snapshot: snapshot)

        XCTAssertEqual(build.buckets.count, 1)
        XCTAssertEqual(build.buckets.first?.model, "gpt-5")
        XCTAssertEqual(build.omittedIncompleteBucketCount, 1)
    }

    func testIngestResponseRequiresExactNonnegativeProcessedCount() {
        XCTAssertTrue(
            DailyUsageIngestResponse(
                created: 1,
                updated: 2,
                unchanged: 3,
                ledgerVersion: 4
            ).isValid(expectedBucketCount: 6)
        )
        XCTAssertFalse(
            DailyUsageIngestResponse(
                created: 1,
                updated: 0,
                unchanged: 0,
                ledgerVersion: 1
            ).isValid(expectedBucketCount: 2)
        )
        XCTAssertFalse(
            DailyUsageIngestResponse(
                created: -1,
                updated: 0,
                unchanged: 2,
                ledgerVersion: 1
            ).isValid(expectedBucketCount: 1)
        )
        XCTAssertTrue(
            DailyUsageIngestResponse(
                created: 0,
                updated: 0,
                unchanged: 1,
                ledgerVersion: 0
            ).isValid(expectedBucketCount: 1)
        )
        XCTAssertFalse(
            DailyUsageIngestResponse(
                created: 0,
                updated: 0,
                unchanged: 1,
                ledgerVersion: -1
            ).isValid(expectedBucketCount: 1)
        )
    }

    func testDailyPayloadContainsOnlyApprovedAggregateFields() throws {
        let bucket = TeamSyncDailyBucket(
            date: "2026-08-09",
            timezone: "Asia/Shanghai",
            tool: "Codex",
            model: "gpt-5",
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 3,
            cacheWriteTokens: 4
        )
        let payload = TeamSyncDailyPayload(
            schemaVersion: 1,
            collectorVersion: "0.2.0",
            generatedAt: "2026-08-09T01:30:00Z",
            buckets: [bucket]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: TeamSyncProtocol.encodedJSON(payload)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["schema_version", "collector_version", "generated_at", "buckets"])
        let rows = try XCTUnwrap(object["buckets"] as? [[String: Any]])
        XCTAssertEqual(
            Set(try XCTUnwrap(rows.first).keys),
            [
                "date", "timezone", "tool", "model", "source", "input_tokens", "output_tokens",
                "cache_read_tokens", "cache_write_tokens", "completeness"
            ]
        )
        let decoded = try JSONDecoder().decode(
            TeamSyncDailyBucket.self,
            from: TeamSyncProtocol.encodedJSON(bucket)
        )
        XCTAssertFalse(decoded.deleted)
    }

    func testServerCompatibleTombstoneRoundTripsWithoutEnablingClientDeletion() throws {
        let exact = TeamSyncDailyBucket(
            date: "2026-08-09",
            timezone: "Asia/Shanghai",
            tool: "Codex",
            model: "gpt-5",
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 3,
            cacheWriteTokens: 4
        )

        let tombstone = TeamSyncDailyBucket(
            date: exact.date,
            timezone: exact.timezone,
            tool: exact.tool,
            model: exact.model,
            source: exact.source,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            deleted: true
        )

        XCTAssertEqual(tombstone.naturalKey, exact.naturalKey)
        XCTAssertTrue(tombstone.deleted)
        XCTAssertEqual(tombstone.inputTokens, 0)
        XCTAssertEqual(tombstone.outputTokens, 0)
        XCTAssertEqual(tombstone.cacheReadTokens, 0)
        XCTAssertEqual(tombstone.cacheWriteTokens, 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: TeamSyncProtocol.encodedJSON(tombstone)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["deleted"] as? Bool, true)
        let decoded = try JSONDecoder().decode(
            TeamSyncDailyBucket.self,
            from: TeamSyncProtocol.encodedJSON(tombstone)
        )
        XCTAssertTrue(decoded.deleted)
    }

    func testNaturalKeySeparatorCannotEnterNewLedgerKeys() throws {
        let separator = TeamSyncProtocolConfiguration.naturalKeySeparator
        let unsafeSnapshot = UsageSnapshot(
            generatedAt: nil,
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 10, cost: 0, activeDays: 1),
            daily: [
                DailyUsage(
                    date: "2026-08-09",
                    tools: ["Co\(separator)dex": 10],
                    models: ["gpt-5": 10],
                    atomicUsage: [
                        DailyAtomicUsage(
                            tool: "Co\(separator)dex",
                            model: "gpt-5",
                            inputTokens: 1,
                            outputTokens: 2,
                            cacheReadTokens: 3,
                            cacheWriteTokens: 4,
                            totalTokens: 10
                        )
                    ],
                    totalTokens: 10,
                    cost: 0
                )
            ],
            tools: [],
            models: [],
            sources: [:]
        )
        XCTAssertThrowsError(
            try TeamSyncProtocol.dailyBucketBuild(snapshot: unsafeSnapshot)
        )
    }

    func testBackoffIsJitteredAndCappedAtSixHours() {
        XCTAssertEqual(
            TeamSyncBackoffPolicy.delay(failureCount: 1, jitterUnit: 0),
            48,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            TeamSyncBackoffPolicy.delay(failureCount: 1, jitterUnit: 1),
            72,
            accuracy: 1e-9
        )
        XCTAssertLessThanOrEqual(
            TeamSyncBackoffPolicy.delay(failureCount: 100, jitterUnit: 1),
            6 * 60 * 60
        )
    }

    func testServerURLRequiresHTTPSOriginWithoutEmbeddedCredentials() {
        XCTAssertThrowsError(try TeamSyncProtocol.normalizedServerURL("http://team.example.com"))
        XCTAssertThrowsError(try TeamSyncProtocol.normalizedServerURL("https://user:pass@team.example.com"))
        XCTAssertThrowsError(try TeamSyncProtocol.normalizedServerURL("https://team.example.com/custom/path"))
        XCTAssertNoThrow(try TeamSyncProtocol.normalizedServerURL("https://team.example.com/"))
    }

    func testDashboardURLIsNormalizedHTTPSOriginWithoutTokens() {
        let dashboardURL = TeamSyncProtocol.dashboardURL(
            serverURL: "  HTTPS://team.example.com:8443/  "
        )
        XCTAssertEqual(dashboardURL?.scheme, "https")
        XCTAssertEqual(dashboardURL?.host, "team.example.com")
        XCTAssertEqual(dashboardURL?.port, 8443)
        XCTAssertEqual(dashboardURL?.path, "")
        XCTAssertNil(dashboardURL?.query)
        XCTAssertNil(dashboardURL?.user)
        XCTAssertNil(TeamSyncProtocol.dashboardURL(serverURL: ""))
        XCTAssertNil(TeamSyncProtocol.dashboardURL(serverURL: "http://team.example.com"))
        XCTAssertNil(
            TeamSyncProtocol.dashboardURL(
                serverURL: "https://team.example.com/?token=must-not-leak"
            )
        )
        XCTAssertNil(
            TeamSyncProtocol.dashboardURL(
                serverURL: "https://user:secret@team.example.com"
            )
        )
    }

    func testPublicLeaderboardURLUsesFixedSameOriginRankPath() throws {
        let url = try XCTUnwrap(
            TeamSyncProtocol.publicLeaderboardURL(
                serverURL: "https://community.example.com:8443",
                isEnrolled: true,
                isScreenshotRendering: false
            )
        )

        XCTAssertEqual(TeamSyncProtocolConfiguration.publicLeaderboardPath, "/rank")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "community.example.com")
        XCTAssertEqual(url.port, 8443)
        XCTAssertEqual(url.path, "/rank")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
    }

    func testPublicLeaderboardURLRejectsMaliciousServerInput() {
        let invalidValues = [
            "",
            "http://community.example.com",
            "https://user:secret@community.example.com",
            "https://community.example.com/private/path",
            "https://community.example.com/?token=must-not-leak",
            "https://community.example.com/#access-token",
            "https://community.example.com/%2e%2e/private",
            "https://community.example.com\n.evil.invalid",
            " HTTPS://community.example.com ",
            "https://community.example.com/"
        ]

        for value in invalidValues {
            XCTAssertNil(
                TeamSyncProtocol.publicLeaderboardURL(
                    serverURL: value,
                    isEnrolled: true,
                    isScreenshotRendering: false
                ),
                "Unexpected leaderboard destination for \(value)"
            )
        }
    }

    func testPublicLeaderboardURLIsUnavailableBeforeEnrollmentAndDuringScreenshotRendering() {
        XCTAssertNil(
            TeamSyncProtocol.publicLeaderboardURL(
                serverURL: "https://community.example.com",
                isEnrolled: false,
                isScreenshotRendering: false
            )
        )
        XCTAssertNil(
            TeamSyncProtocol.publicLeaderboardURL(
                serverURL: "https://community.example.com",
                isEnrolled: true,
                isScreenshotRendering: true
            )
        )
    }
}
