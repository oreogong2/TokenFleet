import CryptoKit
import Foundation
@testable import TokenStepSwift

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

private actor HarnessHTTPClient: TeamSyncHTTPClient {
    var responses: [TeamSyncHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [TeamSyncHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> TeamSyncHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw TeamSyncProtocolError.networkUnavailable }
        return responses.removeFirst()
    }
}

private final class HarnessCredentialStore: TeamSyncCredentialStoring {
    var isAvailable: Bool { true }
    var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func saveDeviceSecret(_ secret: String, deviceID: String) throws { values[deviceID] = secret }
    func loadDeviceSecret(deviceID: String) throws -> String? { values[deviceID] }
    func deleteDeviceSecret(deviceID: String) throws { values.removeValue(forKey: deviceID) }
}

private final class HarnessStateStore: TeamSyncStateStoring {
    var state: TeamSyncPersistentState?

    init(_ state: TeamSyncPersistentState? = nil) {
        self.state = state
    }

    func load() -> TeamSyncPersistentState? { state }
    func save(_ state: TeamSyncPersistentState) throws { self.state = state }
    func delete() throws { state = nil }
}

@main
struct TokenStepLogicHarness {
    static func main() async throws {
        let body = Data(#"{"schema_version":1,"collector_version":"0.2.0","generated_at":"2026-08-09T01:30:00Z","buckets":[{"date":"2026-08-09","timezone":"Asia/Shanghai","tool":"Codex","model":"gpt-5","source":"local","input_tokens":120,"output_tokens":80,"cache_read_tokens":1000,"cache_write_tokens":50,"completeness":"exact"}]}"#.utf8)
        let headers = TeamSyncProtocol.signedHeaders(
            deviceID: "server-device",
            deviceSecret: "test-device-secret-00000000000000000000",
            timestamp: 1_786_240_000,
            nonce: "123e4567-e89b-12d3-a456-426614174000",
            method: "POST",
            path: "/api/v1/usage/daily",
            body: body
        )
        expect(
            headers.signature == "b6f61ec4a68f4693d1baa5115584db1cde917fbc80c376e8d6166af25334bb42",
            "HMAC golden vector mismatch"
        )

        let enrollment = try TeamSyncProtocol.enrollmentURLRequest(
            serverURL: "https://team.example.com",
            enrollmentToken: "one-time",
            devicePublicID: "anonymous",
            appVersion: "0.1.45"
        )
        expect(enrollment.url?.path == "/api/v1/devices/enroll", "Enrollment path mismatch")
        expect(enrollment.value(forHTTPHeaderField: "Authorization") == nil, "Enrollment must not use Authorization")
        let dashboardURL = TeamSyncProtocol.dashboardURL(
            serverURL: " HTTPS://team.example.com:8443/ "
        )
        expect(
            dashboardURL?.scheme == "https"
                && dashboardURL?.host == "team.example.com"
                && dashboardURL?.port == 8443
                && dashboardURL?.path.isEmpty == true
                && dashboardURL?.query == nil
                && dashboardURL?.user == nil,
            "Dashboard URL was not reduced to its HTTPS origin"
        )
        expect(
            TeamSyncProtocol.dashboardURL(
                serverURL: "https://team.example.com/?token=must-not-leak"
            ) == nil,
            "Dashboard URL accepted a token-bearing query"
        )
        expect(
            TeamSyncManualRetryPolicy.allowsForceRetry(
                automaticRetryStopped: true,
                terminalReason: .requestRejected
            ),
            "Request-rejected terminal state disabled explicit recovery"
        )
        expect(
            !TeamSyncManualRetryPolicy.allowsForceRetry(
                automaticRetryStopped: true,
                terminalReason: .credentials
            ),
            "Credential terminal state exposed a force bypass"
        )

        let beta7LeaderboardData = Data(#"{"period":"today","metric":"tokens","timezone":"Asia/Shanghai","mixed_timezones":false,"total_entries":1,"available_tools":["Codex"],"available_models":["gpt-5"],"entries":[{"rank":1,"public_id":"123e4567-e89b-12d3-a456-426614174000","nickname":"奥哥","metric_value":"704000000","totals":{"input_tokens":"4","output_tokens":"0","cache_read_tokens":"704000000","cache_write_tokens":"0","norm_tokens":"4","total_tokens":"704000000","estimated_cost_microunits":null,"cost_currency":null,"unpriced":true,"mixed_currency":false}}]}"#.utf8)
        let beta7Leaderboard = try JSONDecoder().decode(
            TeamSyncPublicLeaderboard.self,
            from: beta7LeaderboardData
        )
        expect(beta7Leaderboard.isValid, "beta.7 public leaderboard response was rejected")
        expect(
            beta7Leaderboard.entries.first?.nickname == "奥哥"
                && beta7Leaderboard.entries.first?.toolCount == 0
                && beta7Leaderboard.entries.first?.primaryTool == nil
                && beta7Leaderboard.entries.first?.modelCount == 0
                && beta7Leaderboard.entries.first?.primaryModel == nil,
            "beta.7 public leaderboard fallback fabricated primary dimensions"
        )

        let partialDimensionData = Data(#"{"period":"today","metric":"tokens","timezone":"Asia/Shanghai","mixed_timezones":false,"total_entries":1,"available_tools":["Codex"],"available_models":[],"entries":[{"rank":1,"public_id":"123e4567-e89b-12d3-a456-426614174000","nickname":"奥哥","metric_value":"704000000","primary_tool":"Codex","totals":{"input_tokens":"4","output_tokens":"0","cache_read_tokens":"704000000","cache_write_tokens":"0","norm_tokens":"4","total_tokens":"704000000","estimated_cost_microunits":null,"cost_currency":null,"unpriced":true,"mixed_currency":false}}]}"#.utf8)
        let partialDimensionBoard = try JSONDecoder().decode(
            TeamSyncPublicLeaderboard.self,
            from: partialDimensionData
        )
        expect(
            !partialDimensionBoard.isValid,
            "Partially supplied beta.8 primary dimension was accepted"
        )

        let legacyData = Data(#"{"date":"2026-08-08","tools":{"Claude Code":70,"Codex":30},"models":{"claude-opus":60,"gpt-5":40},"total_tokens":100,"cost":0}"#.utf8)
        let legacy = try JSONDecoder().decode(DailyUsage.self, from: legacyData)
        expect(legacy.atomicUsage == nil, "Legacy row must remain marginal-only")
        let legacyDetail = HistoryDayDetailViewModel(row: legacy)
        expect(legacyDetail.precision == .legacyMarginals, "Legacy precision mismatch")
        expect(legacyDetail.tools.isEmpty, "Legacy tool-model join was fabricated")

        let codexAtomic = DailyAtomicUsage(
            tool: "Codex",
            model: "gpt-5",
            inputTokens: 120,
            outputTokens: 80,
            cacheReadTokens: 1_000,
            cacheWriteTokens: 50,
            totalTokens: 1_250
        )
        let exact = DailyUsage(
            date: "2026-08-09",
            tools: ["Codex": 1_250],
            models: ["gpt-5": 1_250],
            atomicUsage: [codexAtomic],
            totalTokens: 1_250,
            cost: 0
        )
        let claudeAtomic = DailyAtomicUsage(
            tool: "Claude Code",
            model: "claude-opus",
            inputTokens: 10,
            outputTokens: 3,
            cacheReadTokens: 100,
            cacheWriteTokens: 5,
            totalTokens: 118
        )
        let multiToolDay = DailyUsage(
            date: "2026-08-09",
            tools: ["Codex": 1_250, "Claude Code": 118],
            models: ["gpt-5": 1_250, "claude-opus": 118],
            atomicUsage: [codexAtomic, claudeAtomic],
            totalTokens: 1_368,
            cost: 0
        )
        let multiToolDetail = HistoryDayDetailViewModel(row: multiToolDay)
        expect(multiToolDetail.tools.count == 2, "Same-day tools were collapsed")
        expect(multiToolDetail.tools.flatMap(\.models).count == 2, "Same-day models were collapsed")
        expect(multiToolDetail.exactTotalMatchesDay, "Same-day exact detail does not balance")
        let roundTrippedMultiTool = try JSONDecoder().decode(
            DailyUsage.self,
            from: JSONEncoder().encode(multiToolDay)
        )
        expect(roundTrippedMultiTool.atomicUsage?.count == 2, "Atomic schema round trip lost rows")
        let snapshot = UsageSnapshot(
            generatedAt: nil,
            timezone: "Asia/Singapore",
            totals: UsageTotals(tokens: 1_250, cost: 0, activeDays: 1),
            daily: [legacy, exact],
            tools: [],
            models: [],
            sources: [:]
        )
        let legacyBuild = try TeamSyncProtocol.dailyBucketBuild(snapshot: snapshot)
        let buckets = legacyBuild.buckets
        expect(buckets.count == 1, "Legacy bucket was uploaded")
        expect(
            legacyBuild.omittedIncompleteBucketCount == 1,
            "Legacy marginal day was not reported as omitted"
        )
        expect(buckets[0].timezone == "Asia/Singapore", "Device timezone was not preserved")
        expect(buckets[0].source == "local", "Default source mismatch")
        expect(HistoryDayDetailViewModel(row: exact).exactTotalMatchesDay, "Exact total mismatch")

        let incompleteDay = DailyUsage(
            date: "2026-08-09",
            tools: ["Codex": 100],
            models: ["unknown": 100],
            atomicUsage: [
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
            totalTokens: 100,
            cost: 0
        )
        let incompleteBuild = try TeamSyncProtocol.dailyBucketBuild(
            snapshot: UsageSnapshot(
                generatedAt: nil,
                timezone: "Asia/Shanghai",
                totals: UsageTotals(tokens: 100, cost: 0, activeDays: 1),
                daily: [incompleteDay],
                tools: [],
                models: [],
                sources: [:]
            )
        )
        expect(incompleteBuild.buckets.isEmpty, "Incomplete breakdown was uploaded as exact")
        expect(incompleteBuild.omittedIncompleteBucketCount == 1, "Incomplete omission was not recorded")

        var estimate = buckets[0]
        estimate.completeness = "fallback_estimate"
        expect(estimate.naturalKey == buckets[0].naturalKey, "Completeness must not enter natural key")
        let estimatedHash = try TeamSyncProtocol.contentHash(for: estimate)
        let exactHash = try TeamSyncProtocol.contentHash(for: buckets[0])
        expect(estimatedHash != exactHash, "Completeness must update content hash")
        expect(!buckets[0].deleted, "A normal bucket decoded as a tombstone")
        let protocolTombstone = TeamSyncDailyBucket(
            date: buckets[0].date,
            timezone: buckets[0].timezone,
            tool: buckets[0].tool,
            model: buckets[0].model,
            source: buckets[0].source,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            deleted: true
        )
        expect(protocolTombstone.deleted, "Server-compatible tombstone did not encode deletion")
        expect(
            protocolTombstone.naturalKey == buckets[0].naturalKey,
            "Protocol tombstone changed natural-key identity"
        )
        expect(TeamSyncBackoffPolicy.delay(failureCount: 100, jitterUnit: 1) <= 21_600, "Backoff exceeded six hours")

        let collectorRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepHarness-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = collectorRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: collectorRoot) }
        let claudeLine = #"{"type":"assistant","uuid":"atomic-1","timestamp":"2026-08-09T01:00:00Z","message":{"id":"msg-atomic","model":"claude-opus","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":3,"cache_creation_input_tokens":5,"cache_read_input_tokens":100}}}"#
        try claudeLine.write(
            to: projectRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let collected = UsageCollector.collectClaudeCodeUsageSnapshot(rootURL: collectorRoot)
        let collectedAtomic = collected.daily.first?.atomicUsage?.first
        expect(collectedAtomic?.inputTokens == 10, "Collector did not preserve uncached input")
        expect(collectedAtomic?.outputTokens == 3, "Collector output mismatch")
        expect(collectedAtomic?.cacheReadTokens == 100, "Collector cache read mismatch")
        expect(collectedAtomic?.cacheWriteTokens == 5, "Collector cache write mismatch")
        expect(collectedAtomic?.totalTokens == 118, "Collector atomic total mismatch")

        func assistantLine(
            uuid: String,
            messageID: String?,
            timestamp: String,
            model: String?,
            stopReason: String?,
            input: Int,
            output: Int,
            cacheRead: Int
        ) throws -> String {
            var message: [String: Any] = [
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": cacheRead
                ]
            ]
            if let messageID { message["id"] = messageID }
            if let model { message["model"] = model }
            if let stopReason { message["stop_reason"] = stopReason }
            let object: [String: Any] = [
                "type": "assistant",
                "uuid": uuid,
                "timestamp": timestamp,
                "message": message
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }

        let dedupeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepDedupeHarness-\(UUID().uuidString)", isDirectory: true)
        let dedupeProject = dedupeRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: dedupeProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dedupeRoot) }
        let dedupeLines = try [
            assistantLine(uuid: "block-thinking", messageID: "msg_same_response", timestamp: "2026-06-21T08:00:00Z", model: "claude-opus-4-20250514", stopReason: nil, input: 10, output: 3, cacheRead: 100),
            assistantLine(uuid: "block-text", messageID: "msg_same_response", timestamp: "2026-06-21T08:00:01Z", model: "claude-opus-4-20250514", stopReason: "end_turn", input: 10, output: 3, cacheRead: 100),
            assistantLine(uuid: "tool-1", messageID: "msg_tool_batch", timestamp: "2026-06-21T08:01:00Z", model: "claude-opus-4-20250514", stopReason: nil, input: 7, output: 2, cacheRead: 200),
            assistantLine(uuid: "tool-2", messageID: "msg_tool_batch", timestamp: "2026-06-21T08:01:01Z", model: "claude-opus-4-20250514", stopReason: nil, input: 7, output: 2, cacheRead: 200),
            assistantLine(uuid: "legacy-1", messageID: nil, timestamp: "2026-06-21T08:02:00Z", model: nil, stopReason: "end_turn", input: 1, output: 1, cacheRead: 0),
            assistantLine(uuid: "legacy-1", messageID: nil, timestamp: "2026-06-21T08:02:01Z", model: nil, stopReason: "end_turn", input: 1, output: 1, cacheRead: 0)
        ]
        try dedupeLines.joined(separator: "\n").write(
            to: dedupeProject.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let deduped = UsageCollector.collectClaudeCodeUsageSnapshot(rootURL: dedupeRoot)
        expect(deduped.sources["Claude Code"]?.records == 3, "Claude response/message dedupe count mismatch")
        expect(deduped.totals.tokens == 324, "Claude response/message dedupe total mismatch")
        expect(deduped.daily.first?.atomicUsage?.reduce(0, { $0 + $1.totalTokens }) == 324, "Claude deduped atomic total mismatch")

        let enrollmentPublicID = "123e4567-e89b-12d3-a456-426614174000"
        let firstEnrollmentSecret = "device-secret-0000"
        let rotatedEnrollmentSecret = "rotated-device-secret-0000"
        let enrollmentHTTP = HarnessHTTPClient([
            TeamSyncHTTPResponse(
                data: Data(#"{"device_id":"server-device","device_public_id":"123e4567-e89b-12d3-a456-426614174000","device_secret":"device-secret-0000","signing_key_derivation":"sha256-tokenfleet-hmac-v1"}"#.utf8),
                statusCode: 201
            ),
            TeamSyncHTTPResponse(
                data: Data(#"{"device_id":"server-device","device_public_id":"123e4567-e89b-12d3-a456-426614174000","device_secret":"rotated-device-secret-0000","signing_key_derivation":"sha256-tokenfleet-hmac-v1"}"#.utf8),
                statusCode: 201
            )
        ])
        let enrollmentCredentials = HarnessCredentialStore()
        let enrollmentState = HarnessStateStore(
            TeamSyncPersistentState(serverURL: "", devicePublicID: enrollmentPublicID)
        )
        let enrollmentService = TeamSyncService(
            httpClient: enrollmentHTTP,
            credentialStore: enrollmentCredentials,
            stateStore: enrollmentState
        )
        let enrolled = try await enrollmentService.enroll(
            serverURL: "https://team.example.com",
            enrollmentToken: "one-time",
            appVersion: "0.1.45",
            now: Date(timeIntervalSince1970: 100)
        )
        expect(enrolled.deviceID == "server-device", "Server device ID was not preserved")
        expect(enrollmentCredentials.values["server-device"] == firstEnrollmentSecret, "Secret was not isolated in credential store")
        try await enrollmentService.clear()
        expect(enrollmentCredentials.values["server-device"] == nil, "Clear retained the old device secret")
        expect(enrollmentState.state?.devicePublicID == enrolled.devicePublicID, "Clear replaced the stable installation ID")
        expect(enrollmentState.state?.deviceID == nil, "Clear retained the server device binding")
        expect(enrollmentState.state?.serverURL == "", "Clear retained the server URL")
        let reenrolled = try await enrollmentService.enroll(
            serverURL: "https://team.example.com",
            enrollmentToken: "second-one-time",
            appVersion: "0.1.45",
            now: Date(timeIntervalSince1970: 200)
        )
        expect(reenrolled.deviceID == enrolled.deviceID, "Re-enrollment replaced the server device ID")
        expect(enrollmentCredentials.values["server-device"] == rotatedEnrollmentSecret, "Re-enrollment did not rotate the secret")
        let enrollmentRequests = await enrollmentHTTP.requests
        expect(enrollmentRequests.count == 2, "Enrollment request count mismatch")
        let firstEnrollmentPayload = try JSONDecoder().decode(
            TeamSyncEnrollmentRequest.self,
            from: enrollmentRequests[0].httpBody ?? Data()
        )
        let secondEnrollmentPayload = try JSONDecoder().decode(
            TeamSyncEnrollmentRequest.self,
            from: enrollmentRequests[1].httpBody ?? Data()
        )
        expect(
            secondEnrollmentPayload.devicePublicID == firstEnrollmentPayload.devicePublicID,
            "Clear and re-enroll changed the installation identity"
        )

        let badDerivationHTTP = HarnessHTTPClient([
            TeamSyncHTTPResponse(
                data: Data(#"{"device_id":"bad-device","device_public_id":"123e4567-e89b-12d3-a456-426614174000","device_secret":"must-not-store-secret-0000","signing_key_derivation":"legacy-direct-secret"}"#.utf8),
                statusCode: 201
            )
        ])
        let badDerivationCredentials = HarnessCredentialStore()
        let badDerivationService = TeamSyncService(
            httpClient: badDerivationHTTP,
            credentialStore: badDerivationCredentials,
            stateStore: HarnessStateStore(
                TeamSyncPersistentState(serverURL: "", devicePublicID: enrollmentPublicID)
            )
        )
        _ = try? await badDerivationService.enroll(
            serverURL: "https://team.example.com",
            enrollmentToken: "one-time"
        )
        expect(badDerivationCredentials.values.isEmpty, "Unexpected derivation stored a secret")

        let syncHTTP = HarnessHTTPClient([
            TeamSyncHTTPResponse(
                data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":1}"#.utf8),
                statusCode: 200
            ),
            TeamSyncHTTPResponse(
                data: Data(#"{"created":0,"updated":0,"unchanged":1,"ledger_version":2}"#.utf8),
                statusCode: 200
            )
        ])
        let syncState = HarnessStateStore(
            TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let syncService = TeamSyncService(
            httpClient: syncHTTP,
            credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
            stateStore: syncState
        )
        _ = try await syncService.synchronize(
            snapshot: UsageSnapshot(
                generatedAt: nil,
                timezone: "Asia/Shanghai",
                totals: UsageTotals(tokens: 1_250, cost: 0, activeDays: 1),
                daily: [exact],
                tools: [],
                models: [],
                sources: [:]
            ),
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )
        _ = try await syncService.synchronize(
            snapshot: UsageSnapshot(
                generatedAt: nil,
                timezone: "Asia/Shanghai",
                totals: UsageTotals(tokens: 1_250, cost: 0, activeDays: 1),
                daily: [exact],
                tools: [],
                models: [],
                sources: [:]
            ),
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_100)
        )
        _ = try await syncService.synchronize(
            snapshot: UsageSnapshot(
                generatedAt: nil,
                timezone: "Asia/Shanghai",
                totals: UsageTotals(tokens: 1_250, cost: 0, activeDays: 1),
                daily: [exact],
                tools: [],
                models: [],
                sources: [:]
            ),
            serverURL: "https://team.example.com",
            force: false,
            now: Date(timeIntervalSince1970: 1_786_240_200)
        )
        let syncRequests = await syncHTTP.requests
        expect(syncRequests.count == 2, "Force did not retransmit the exact bucket")
        expect(syncState.state?.syncedBucketHashes.count == 1, "Bucket hash was not persisted")
        expect(syncState.state?.lastLedgerVersion == 2, "Forced retransmit ledger was not persisted")

        let authoritativeSnapshot = UsageSnapshot(
            generatedAt: nil,
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 1_250, cost: 0, activeDays: 1),
            daily: [exact],
            tools: [],
            models: [],
            sources: [:]
        )
        let authoritativeBucket = try TeamSyncProtocol.dailyBuckets(
            snapshot: authoritativeSnapshot
        )[0]
        let authoritativeHash = try TeamSyncProtocol.contentHash(for: authoritativeBucket)
        let staleBucket = TeamSyncDailyBucket(
            date: "2026-08-09",
            timezone: "Asia/Shanghai",
            tool: "Claude Code",
            model: "claude-old",
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 3,
            cacheWriteTokens: 4
        )
        let staleKey = staleBucket.naturalKey

        let emptySnapshotHTTP = HarnessHTTPClient([])
        let emptySnapshotState = HarnessStateStore(
            TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 3,
                syncedBucketHashes: [staleKey: "active-hash"]
            )
        )
        let emptySnapshotService = TeamSyncService(
            httpClient: emptySnapshotHTTP,
            credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
            stateStore: emptySnapshotState
        )
        _ = try await emptySnapshotService.synchronize(
            snapshot: .empty,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_250)
        )
        let emptySnapshotRequests = await emptySnapshotHTTP.requests
        expect(emptySnapshotRequests.isEmpty, "Empty snapshot sent a deletion request")
        expect(
            emptySnapshotState.state?.syncedBucketHashes[staleKey] == "active-hash",
            "Empty snapshot discarded an active ledger hash"
        )

        var priorDayBucket = staleBucket
        priorDayBucket.date = "2026-08-08"
        let partialSnapshotHTTP = HarnessHTTPClient([])
        let partialSnapshotState = HarnessStateStore(
            TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 3,
                syncedBucketHashes: [
                    authoritativeBucket.naturalKey: authoritativeHash,
                    priorDayBucket.naturalKey: "prior-day-hash"
                ]
            )
        )
        let partialSnapshotService = TeamSyncService(
            httpClient: partialSnapshotHTTP,
            credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
            stateStore: partialSnapshotState
        )
        _ = try await partialSnapshotService.synchronize(
            snapshot: authoritativeSnapshot,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_275)
        )
        let partialSnapshotRequests = await partialSnapshotHTTP.requests
        expect(partialSnapshotRequests.isEmpty, "Partial history deleted a whole missing day")
        expect(
            partialSnapshotState.state?.syncedBucketHashes[priorDayBucket.naturalKey]
                == "prior-day-hash",
            "Partial history discarded the missing day's ledger hash"
        )

        let missingSourceHTTP = HarnessHTTPClient([
            TeamSyncHTTPResponse(
                data: Data(#"{"created":0,"updated":0,"unchanged":1,"ledger_version":4}"#.utf8),
                statusCode: 200
            )
        ])
        let missingSourceState = HarnessStateStore(
            TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 3,
                syncedBucketHashes: [
                    authoritativeBucket.naturalKey: authoritativeHash,
                    staleKey: "stale-hash"
                ]
            )
        )
        let missingSourceService = TeamSyncService(
            httpClient: missingSourceHTTP,
            credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
            stateStore: missingSourceState
        )
        _ = try await missingSourceService.synchronize(
            snapshot: authoritativeSnapshot,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_300)
        )
        var missingSourceRequests = await missingSourceHTTP.requests
        expect(
            missingSourceRequests.isEmpty,
            "Ordinary sync deleted a temporarily missing same-day source"
        )
        _ = try await missingSourceService.synchronize(
            snapshot: authoritativeSnapshot,
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_400)
        )
        missingSourceRequests = await missingSourceHTTP.requests
        expect(missingSourceRequests.count == 1, "Force did not upload the current exact bucket")
        let forcedPayload = try JSONDecoder().decode(
            TeamSyncDailyPayload.self,
            from: missingSourceRequests[0].httpBody ?? Data()
        )
        expect(
            forcedPayload.buckets.count == 1 && forcedPayload.buckets.allSatisfy { !$0.deleted },
            "Force synthesized a tombstone for a temporarily missing source"
        )
        expect(
            missingSourceState.state?.syncedBucketHashes[staleKey] == "stale-hash",
            "Missing-source hash was discarded"
        )

        let legacyMarkerHTTP = HarnessHTTPClient([
            TeamSyncHTTPResponse(
                data: Data(#"{"created":0,"updated":0,"unchanged":1,"ledger_version":5}"#.utf8),
                statusCode: 200
            )
        ])
        let legacyMarkerState = HarnessStateStore(
            TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 4,
                syncedBucketHashes: [
                    authoritativeBucket.naturalKey: authoritativeHash,
                    staleKey: TeamSyncProtocolConfiguration.deletedLedgerMarker
                ]
            )
        )
        let legacyMarkerService = TeamSyncService(
            httpClient: legacyMarkerHTTP,
            credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
            stateStore: legacyMarkerState
        )
        _ = try await legacyMarkerService.synchronize(
            snapshot: authoritativeSnapshot,
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_450)
        )
        let legacyMarkerRequests = await legacyMarkerHTTP.requests
        let legacyMarkerPayload = try JSONDecoder().decode(
            TeamSyncDailyPayload.self,
            from: legacyMarkerRequests.first?.httpBody ?? Data()
        )
        expect(
            legacyMarkerPayload.buckets.count == 1
                && legacyMarkerPayload.buckets.allSatisfy { !$0.deleted },
            "Force retransmitted a legacy deletion marker"
        )
        expect(
            legacyMarkerState.state?.syncedBucketHashes[staleKey]
                == TeamSyncProtocolConfiguration.deletedLedgerMarker,
            "Force discarded the legacy local marker"
        )

        let unsafeLedgerKey = "unsafe-legacy-key"
        let unsafeDeletionHTTP = HarnessHTTPClient([])
        let unsafeDeletionState = HarnessStateStore(
            TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                syncedBucketHashes: [unsafeLedgerKey: "stale-hash"]
            )
        )
        let unsafeDeletionService = TeamSyncService(
            httpClient: unsafeDeletionHTTP,
            credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
            stateStore: unsafeDeletionState
        )
        _ = try await unsafeDeletionService.synchronize(
            snapshot: .empty,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_600)
        )
        expect(
            unsafeDeletionState.state?.syncedBucketHashes[unsafeLedgerKey] == "stale-hash",
            "Opaque stale natural key was discarded"
        )
        expect(
            unsafeDeletionState.state?.lastOmittedIncompleteBucketCount == 0,
            "Retained stale state was reported as an upload omission"
        )
        let unsafeDeletionRequests = await unsafeDeletionHTTP.requests
        expect(unsafeDeletionRequests.isEmpty, "Unsafe natural key reached the server")

        for transientStatus in [408, 425] {
            let transientHTTP = HarnessHTTPClient([
                TeamSyncHTTPResponse(data: Data(), statusCode: transientStatus),
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":6}"#.utf8),
                    statusCode: 200
                )
            ])
            let transientState = HarnessStateStore(
                TeamSyncPersistentState(
                    serverURL: "https://team.example.com",
                    devicePublicID: "anonymous",
                    deviceID: "server-device"
                )
            )
            let transientService = TeamSyncService(
                httpClient: transientHTTP,
                credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
                stateStore: transientState
            )
            _ = try? await transientService.synchronize(
                snapshot: authoritativeSnapshot,
                serverURL: "https://team.example.com",
                force: true,
                now: Date(timeIntervalSince1970: 1_786_240_700)
            )
            let retryAt = transientState.state?.nextAttemptAt
            expect(retryAt != nil, "HTTP \(transientStatus) did not enter backoff")
            expect(
                transientState.state?.automaticRetryStopped == false,
                "HTTP \(transientStatus) became terminal"
            )
            _ = try await transientService.synchronize(
                snapshot: authoritativeSnapshot,
                serverURL: "https://team.example.com",
                force: transientStatus == 408,
                now: transientStatus == 408
                    ? Date(timeIntervalSince1970: 1_786_240_701)
                    : retryAt!
            )
            let transientRequests = await transientHTTP.requests
            expect(transientRequests.count == 2, "HTTP \(transientStatus) did not recover")
            expect(
                transientState.state?.lastLedgerVersion == 6
                    && transientState.state?.nextAttemptAt == nil,
                "HTTP \(transientStatus) recovery state mismatch"
            )
        }

        let rejectedHTTP = HarnessHTTPClient([
            TeamSyncHTTPResponse(data: Data(), statusCode: 422),
            TeamSyncHTTPResponse(
                data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":7}"#.utf8),
                statusCode: 200
            )
        ])
        let rejectedState = HarnessStateStore(
            TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let rejectedService = TeamSyncService(
            httpClient: rejectedHTTP,
            credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
            stateStore: rejectedState
        )
        _ = try? await rejectedService.synchronize(
            snapshot: UsageSnapshot(
                generatedAt: nil,
                timezone: "Asia/Shanghai",
                totals: UsageTotals(tokens: 1_250, cost: 0, activeDays: 1),
                daily: [exact],
                tools: [],
                models: [],
                sources: [:]
            ),
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )
        expect(rejectedState.state?.automaticRetryStopped == true, "Terminal 4xx kept retrying")
        expect(rejectedState.state?.terminalReason == .requestRejected, "Terminal 4xx reason mismatch")
        _ = try? await rejectedService.synchronize(
            snapshot: authoritativeSnapshot,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_100)
        )
        var rejectedRequests = await rejectedHTTP.requests
        expect(rejectedRequests.count == 1, "Automatic work bypassed terminal 422")
        _ = try await rejectedService.synchronize(
            snapshot: authoritativeSnapshot,
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_200)
        )
        rejectedRequests = await rejectedHTTP.requests
        expect(rejectedRequests.count == 2, "Explicit force did not recover terminal 422")
        expect(
            rejectedState.state?.automaticRetryStopped == false
                && rejectedState.state?.terminalReason == nil,
            "Recovered 422 remained terminal"
        )

        for credentialStatus in [401, 403] {
            let credentialHTTP = HarnessHTTPClient([
                TeamSyncHTTPResponse(data: Data(), statusCode: credentialStatus)
            ])
            let credentialState = HarnessStateStore(
                TeamSyncPersistentState(
                    serverURL: "https://team.example.com",
                    devicePublicID: "anonymous",
                    deviceID: "server-device"
                )
            )
            let credentialService = TeamSyncService(
                httpClient: credentialHTTP,
                credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
                stateStore: credentialState
            )
            _ = try? await credentialService.synchronize(
                snapshot: authoritativeSnapshot,
                serverURL: "https://team.example.com",
                force: true,
                now: Date(timeIntervalSince1970: 1_786_240_300)
            )
            _ = try? await credentialService.synchronize(
                snapshot: authoritativeSnapshot,
                serverURL: "https://team.example.com",
                force: true,
                now: Date(timeIntervalSince1970: 1_786_240_400)
            )
            let credentialRequests = await credentialHTTP.requests
            expect(
                credentialRequests.count == 1
                    && credentialState.state?.terminalReason == .credentials,
                "Force bypassed credential rejection \(credentialStatus)"
            )
        }

        let retentionOnlyHTTP = HarnessHTTPClient([
            TeamSyncHTTPResponse(
                data: Data(#"{"created":0,"updated":0,"unchanged":1,"ledger_version":0}"#.utf8),
                statusCode: 200
            )
        ])
        let retentionOnlyState = HarnessStateStore(
            TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let retentionOnlyService = TeamSyncService(
            httpClient: retentionOnlyHTTP,
            credentialStore: HarnessCredentialStore(["server-device": "device-secret"]),
            stateStore: retentionOnlyState
        )
        _ = try await retentionOnlyService.synchronize(
            snapshot: UsageSnapshot(
                generatedAt: nil,
                timezone: "Asia/Shanghai",
                totals: UsageTotals(tokens: 1_250, cost: 0, activeDays: 1),
                daily: [exact],
                tools: [],
                models: [],
                sources: [:]
            ),
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )
        expect(
            retentionOnlyState.state?.syncedBucketHashes.count == 1,
            "Retention-only success did not persist the client content hash"
        )
        expect(
            retentionOnlyState.state?.lastLedgerVersion == 0,
            "Retention-only success rejected ledger version zero"
        )
        expect(
            retentionOnlyState.state?.automaticRetryStopped == false
                && retentionOnlyState.state?.terminalReason == nil,
            "Retention-only success entered terminal state"
        )
        print("TokenStep logic harness passed")
    }
}
