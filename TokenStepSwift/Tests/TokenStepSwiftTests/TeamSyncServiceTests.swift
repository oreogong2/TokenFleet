import Foundation
import XCTest
@testable import TokenStepSwift

final class TeamSyncServiceTests: XCTestCase {
    func testManualRetryPolicyKeepsRequestRejectedReachableButBlocksCredentials() {
        XCTAssertTrue(
            TeamSyncManualRetryPolicy.allowsForceRetry(
                automaticRetryStopped: false,
                terminalReason: nil
            )
        )
        XCTAssertTrue(
            TeamSyncManualRetryPolicy.allowsForceRetry(
                automaticRetryStopped: true,
                terminalReason: .requestRejected
            )
        )
        XCTAssertFalse(
            TeamSyncManualRetryPolicy.allowsForceRetry(
                automaticRetryStopped: true,
                terminalReason: .credentials
            )
        )
        XCTAssertFalse(
            TeamSyncManualRetryPolicy.allowsForceRetry(
                automaticRetryStopped: true,
                terminalReason: nil
            )
        )
    }

    func testDisabledCredentialStorageRejectsBeforeEnrollmentTokenIsSent() async {
        let http = RecordingTeamSyncHTTPClient(
            responses: [TeamSyncHTTPResponse(data: Data(), statusCode: 200)]
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: DisabledTeamSyncCredentialStore(),
            stateStore: MemoryTeamSyncStateStore()
        )

        do {
            _ = try await service.enroll(
                serverURL: "https://team.example.com",
                enrollmentToken: "must-not-be-consumed"
            )
            XCTFail("Expected secure storage gate")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .secureCredentialStorageUnavailable)
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testEnrollmentStoresSecretOutsidePersistentStateAndUsesServerDeviceID() async throws {
        let stablePublicID = "123e4567-e89b-12d3-a456-426614174000"
        let deviceSecret = "test-device-secret-0123456789"
        let response = TeamSyncHTTPResponse(
            data: Data(#"{"device_id":"server-device-42","device_public_id":"123e4567-e89b-12d3-a456-426614174000","device_secret":"test-device-secret-0123456789","signing_key_derivation":"sha256-tokenfleet-hmac-v1"}"#.utf8),
            statusCode: 201
        )
        let http = RecordingTeamSyncHTTPClient(responses: [response])
        let credentials = MemoryTeamSyncCredentialStore()
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(serverURL: "", devicePublicID: stablePublicID)
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: credentials,
            stateStore: stateStore
        )

        let state = try await service.enroll(
            serverURL: "https://team.example.com",
            enrollmentToken: "one-time",
            appVersion: "0.1.45",
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(state.deviceID, "server-device-42")
        XCTAssertEqual(credentials.values["server-device-42"], deviceSecret)
        let encodedState = String(data: try JSONEncoder().encode(state), encoding: .utf8) ?? ""
        XCTAssertFalse(encodedState.contains(deviceSecret))
        XCTAssertFalse(encodedState.contains("one-time"))
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.path, "/api/v1/devices/enroll")
    }

    func testCommunityRankUsesStoredDeviceCredentialAndValidatesResponse() async throws {
        let origin = "https://team.example.com"
        let deviceID = "server-device-42"
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(
                    data: Data(#"{"public_id":"123e4567-e89b-12d3-a456-426614174000","nickname":"奥哥","public_profile_enabled":true,"period":"today","metric":"tokens","rank":2,"total_entries":10,"metric_value":"704000000"}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: [deviceID: "test-device-secret-0123456789"]
            ),
            stateStore: MemoryTeamSyncStateStore(
                state: TeamSyncPersistentState(
                    serverURL: origin,
                    devicePublicID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    deviceID: deviceID
                )
            )
        )

        let rank = try await service.fetchCommunityRank(
            serverURL: origin,
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )

        XCTAssertEqual(rank.rank, 2)
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/devices/me/community-rank")
        XCTAssertNil(request.httpBody)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Signature"))
    }

    func testPublicLeaderboardUsesNoCredentialOrEnrollmentState() async throws {
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(
                    data: Data(#"{"period":"today","metric":"tokens","timezone":"Asia/Shanghai","mixed_timezones":false,"total_entries":1,"available_tools":["Codex"],"available_models":["gpt-5"],"entries":[{"rank":1,"public_id":"123e4567-e89b-12d3-a456-426614174000","nickname":"甲","metric_value":"330","primary_tool":"Codex","primary_tool_tokens":"330","tool_count":1,"primary_model":"gpt-5","primary_model_tokens":"330","model_count":1,"totals":{"input_tokens":"10","output_tokens":"20","cache_read_tokens":"300","cache_write_tokens":"0","norm_tokens":"30","total_tokens":"330","estimated_cost_microunits":null,"cost_currency":null,"unpriced":true,"mixed_currency":false}}]}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: DisabledTeamSyncCredentialStore(),
            stateStore: MemoryTeamSyncStateStore()
        )

        let board = try await service.fetchPublicLeaderboard(
            serverURL: "https://team.example.com"
        )

        XCTAssertEqual(board.entries.first?.nickname, "甲")
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Device-ID"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Signature"))
    }

    func testEnrollmentRejectsUnexpectedSigningKeyDerivationBeforeStoringSecret() async {
        let stablePublicID = "123e4567-e89b-12d3-a456-426614174000"
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(
                    data: Data(#"{"device_id":"server-device-42","device_public_id":"123e4567-e89b-12d3-a456-426614174000","device_secret":"must-not-store-secret-012345","signing_key_derivation":"legacy-direct-secret"}"#.utf8),
                    statusCode: 201
                )
            ]
        )
        let credentials = MemoryTeamSyncCredentialStore()
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(serverURL: "", devicePublicID: stablePublicID)
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: credentials,
            stateStore: stateStore
        )

        do {
            _ = try await service.enroll(
                serverURL: "https://team.example.com",
                enrollmentToken: "one-time"
            )
            XCTFail("Expected signing derivation rejection")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .invalidEnrollmentResponse)
        }
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertEqual(stateStore.state?.devicePublicID, stablePublicID)
        XCTAssertFalse(stateStore.state?.isEnrolled == true)
    }

    func testReenrollmentStateFailureKeepsServerRotatedSecretForSameBinding() async {
        let publicID = "123e4567-e89b-12d3-a456-426614174000"
        let origin = "https://team.example.com"
        let deviceID = "server-device-42"
        let credentials = BindingMemoryCredentialStore(
            serverURL: origin,
            deviceID: deviceID,
            secret: "previous-device-secret-012345"
        )
        let stateStore = ThrowingSaveTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: origin,
                devicePublicID: publicID,
                deviceID: deviceID
            )
        )
        let service = TeamSyncService(
            httpClient: RecordingTeamSyncHTTPClient(
                responses: [
                    TeamSyncHTTPResponse(
                        data: Data(#"{"device_id":"server-device-42","device_public_id":"123e4567-e89b-12d3-a456-426614174000","device_secret":"rotated-device-secret-012345","signing_key_derivation":"sha256-tokenfleet-hmac-v1"}"#.utf8),
                        statusCode: 201
                    )
                ]
            ),
            credentialStore: credentials,
            stateStore: stateStore
        )

        do {
            _ = try await service.enroll(
                serverURL: origin,
                enrollmentToken: "one-time"
            )
            XCTFail("Expected state persistence failure")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .stateUnavailable)
        }
        XCTAssertEqual(credentials.serverURL, origin)
        XCTAssertEqual(credentials.deviceID, deviceID)
        XCTAssertEqual(credentials.secret, "rotated-device-secret-012345")
    }

    func testEnrollmentStateFailureRestoresPreviousDifferentBinding() async {
        let publicID = "123e4567-e89b-12d3-a456-426614174000"
        let credentials = BindingMemoryCredentialStore(
            serverURL: "https://previous.example.com",
            deviceID: "previous-device",
            secret: "previous-device-secret-012345"
        )
        let stateStore = ThrowingSaveTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://previous.example.com",
                devicePublicID: publicID,
                deviceID: "previous-device"
            )
        )
        let service = TeamSyncService(
            httpClient: RecordingTeamSyncHTTPClient(
                responses: [
                    TeamSyncHTTPResponse(
                        data: Data(#"{"device_id":"replacement-device","device_public_id":"123e4567-e89b-12d3-a456-426614174000","device_secret":"replacement-secret-0123456789","signing_key_derivation":"sha256-tokenfleet-hmac-v1"}"#.utf8),
                        statusCode: 201
                    )
                ]
            ),
            credentialStore: credentials,
            stateStore: stateStore
        )

        do {
            _ = try await service.enroll(
                serverURL: "https://replacement.example.com",
                enrollmentToken: "one-time"
            )
            XCTFail("Expected state persistence failure")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .stateUnavailable)
        }
        XCTAssertEqual(credentials.serverURL, "https://previous.example.com")
        XCTAssertEqual(credentials.deviceID, "previous-device")
        XCTAssertEqual(credentials.secret, "previous-device-secret-012345")
    }

    func testClearCancelsSuspendedEnrollmentAndConcurrentOperation() async throws {
        let publicID = "123e4567-e89b-12d3-a456-426614174000"
        let http = SuspendedTeamSyncHTTPClient(mode: .enrollment)
        let credentials = MemoryTeamSyncCredentialStore()
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(serverURL: "", devicePublicID: publicID)
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: credentials,
            stateStore: stateStore
        )

        let enrollment = Task {
            try await service.enroll(
                serverURL: "https://team.example.com",
                enrollmentToken: "one-time"
            )
        }
        await http.waitUntilStarted()

        do {
            _ = try await service.enroll(
                serverURL: "https://team.example.com",
                enrollmentToken: "second-one-time"
            )
            XCTFail("Expected single-flight rejection")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .operationInProgress)
        }

        try await service.clear()
        await http.resume()
        do {
            _ = try await enrollment.value
            XCTFail("Expected cancelled enrollment")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .operationCancelled)
        }
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertEqual(stateStore.state?.devicePublicID, publicID)
        XCTAssertFalse(stateStore.state?.isEnrolled == true)
    }

    func testClearCancelsSuspendedSyncWithoutRestoringState() async throws {
        let publicID = "123e4567-e89b-12d3-a456-426614174000"
        let http = SuspendedTeamSyncHTTPClient(mode: .ingest)
        let credentials = MemoryTeamSyncCredentialStore(
            values: ["server-device": "device-secret"]
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: publicID,
                deviceID: "server-device"
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: credentials,
            stateStore: stateStore
        )

        let synchronization = Task {
            try await service.synchronize(
                snapshot: exactSnapshot(),
                serverURL: "https://team.example.com",
                force: true,
                now: Date(timeIntervalSince1970: 1_786_240_000)
            )
        }
        await http.waitUntilStarted()
        try await service.clear()
        await http.resume()
        do {
            _ = try await synchronization.value
            XCTFail("Expected cancelled synchronization")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .operationCancelled)
        }
        XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertEqual(stateStore.state?.devicePublicID, publicID)
        XCTAssertFalse(stateStore.state?.isEnrolled == true)
        XCTAssertTrue(stateStore.state?.syncedBucketHashes.isEmpty == true)
    }

    func testCredentialLoadFailureStopsBeforeHTTP() async {
        let http = RecordingTeamSyncHTTPClient(responses: [])
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "123e4567-e89b-12d3-a456-426614174000",
                deviceID: "server-device"
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: FailingLoadTeamSyncCredentialStore(),
            stateStore: stateStore
        )

        do {
            _ = try await service.synchronize(
                snapshot: exactSnapshot(),
                serverURL: "https://team.example.com",
                force: true
            )
            XCTFail("Expected locked credential store")
        } catch {
            XCTAssertEqual(
                error as? TeamSyncProtocolError,
                .credentialStoreTemporarilyUnavailable
            )
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(stateStore.state?.automaticRetryStopped == true)
        XCTAssertNotNil(stateStore.state?.nextAttemptAt)
    }

    func testClearThenReenrollPreservesPublicIDAndRemovesCredential() async throws {
        let stablePublicID = "123e4567-e89b-12d3-a456-426614174000"
        let previousDeviceID = "previous-server-device"
        let response = TeamSyncHTTPResponse(
            data: Data(#"{"device_id":"replacement-server-device","device_public_id":"123e4567-e89b-12d3-a456-426614174000","device_secret":"replacement-secret","signing_key_derivation":"sha256-tokenfleet-hmac-v1"}"#.utf8),
            statusCode: 201
        )
        let http = RecordingTeamSyncHTTPClient(responses: [response])
        let credentials = MemoryTeamSyncCredentialStore(
            values: [previousDeviceID: "previous-secret"]
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://previous.example.com",
                devicePublicID: stablePublicID,
                deviceID: previousDeviceID,
                enrolledAt: Date(timeIntervalSince1970: 10),
                lastSyncAt: Date(timeIntervalSince1970: 20),
                lastError: "previous error",
                failureCount: 3,
                nextAttemptAt: Date(timeIntervalSince1970: 30),
                automaticRetryStopped: true,
                terminalReason: .requestRejected,
                lastOmittedIncompleteBucketCount: 2,
                lastLedgerVersion: 4,
                syncedBucketHashes: ["old-bucket": "old-hash"]
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: credentials,
            stateStore: stateStore
        )

        try await service.clear()

        XCTAssertNil(credentials.values[previousDeviceID])
        let clearedState = try XCTUnwrap(stateStore.state)
        XCTAssertEqual(clearedState.devicePublicID, stablePublicID)
        XCTAssertEqual(clearedState.serverURL, "")
        XCTAssertNil(clearedState.deviceID)
        XCTAssertNil(clearedState.enrolledAt)
        XCTAssertNil(clearedState.lastSyncAt)
        XCTAssertNil(clearedState.lastError)
        XCTAssertEqual(clearedState.failureCount, 0)
        XCTAssertNil(clearedState.nextAttemptAt)
        XCTAssertFalse(clearedState.automaticRetryStopped)
        XCTAssertNil(clearedState.terminalReason)
        XCTAssertEqual(clearedState.lastOmittedIncompleteBucketCount, 0)
        XCTAssertNil(clearedState.lastLedgerVersion)
        XCTAssertTrue(clearedState.syncedBucketHashes.isEmpty)
        XCTAssertFalse(clearedState.isEnrolled)

        _ = try await service.enroll(
            serverURL: "https://replacement.example.com",
            enrollmentToken: "replacement-token"
        )

        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["device_public_id"] as? String, stablePublicID)
        XCTAssertNil(credentials.values[previousDeviceID])
        XCTAssertEqual(
            credentials.values["replacement-server-device"],
            "replacement-secret"
        )
        XCTAssertEqual(stateStore.state?.devicePublicID, stablePublicID)
        XCTAssertEqual(stateStore.state?.deviceID, "replacement-server-device")
    }

    func testForcedSyncRetransmitsUnchangedExactBucketAndUsesReturnedDeviceID() async throws {
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":1}"#.utf8),
                    statusCode: 200
                ),
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":0,"updated":0,"unchanged":1,"ledger_version":2}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let credentials = MemoryTeamSyncCredentialStore(values: ["server-device": "device-secret"])
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: credentials,
            stateStore: stateStore
        )
        let snapshot = exactSnapshot()

        _ = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )
        _ = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_100)
        )

        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "X-Device-ID"), "server-device")
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/usage/daily")
        XCTAssertEqual(stateStore.state?.syncedBucketHashes.count, 1)
        XCTAssertEqual(stateStore.state?.lastLedgerVersion, 2)
        XCTAssertEqual(stateStore.state?.lastOmittedIncompleteBucketCount, 1)
        XCTAssertEqual(stateStore.state?.lastSyncAt, Date(timeIntervalSince1970: 1_786_240_100))
    }

    func testNonForcedSyncSkipsUnchangedExactBucket() async throws {
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":1}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )

        _ = try await service.synchronize(
            snapshot: exactSnapshot(),
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )
        _ = try await service.synchronize(
            snapshot: exactSnapshot(),
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_100)
        )

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(stateStore.state?.lastLedgerVersion, 1)
        XCTAssertEqual(
            stateStore.state?.lastSyncAt,
            Date(timeIntervalSince1970: 1_786_240_100)
        )
    }

    func testEmptySnapshotKeepsSyncedHashAndDoesNotSendTombstone() async throws {
        let syncedBucket = ledgerBucket(date: "2026-08-08")
        let http = RecordingTeamSyncHTTPClient(responses: [])
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 3,
                syncedBucketHashes: [syncedBucket.naturalKey: "active-hash"]
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )

        let state = try await service.synchronize(
            snapshot: .empty,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )

        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(state.syncedBucketHashes[syncedBucket.naturalKey], "active-hash")
        XCTAssertEqual(state.lastLedgerVersion, 3)
        XCTAssertEqual(state.lastOmittedIncompleteBucketCount, 0)
    }

    func testWholeMissingDateIsNotTombstonedByPartialHistorySnapshot() async throws {
        let snapshot = authoritativeSnapshot(date: "2026-08-09")
        let currentBucket = try XCTUnwrap(
            TeamSyncProtocol.dailyBuckets(snapshot: snapshot).first
        )
        let currentHash = try TeamSyncProtocol.contentHash(for: currentBucket)
        let priorDayBucket = ledgerBucket(date: "2026-08-08")
        let http = RecordingTeamSyncHTTPClient(responses: [])
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 3,
                syncedBucketHashes: [
                    currentBucket.naturalKey: currentHash,
                    priorDayBucket.naturalKey: "prior-day-hash"
                ]
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )

        let state = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )

        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(
            state.syncedBucketHashes[priorDayBucket.naturalKey],
            "prior-day-hash"
        )
        XCTAssertEqual(state.syncedBucketHashes[currentBucket.naturalKey], currentHash)
    }

    func testTemporarilyMissingSameDayToolIsNeverDeletedEvenWhenForced() async throws {
        let snapshot = authoritativeSnapshot()
        let currentBucket = try XCTUnwrap(
            TeamSyncProtocol.dailyBuckets(snapshot: snapshot).first
        )
        let currentHash = try TeamSyncProtocol.contentHash(for: currentBucket)
        let staleBucket = ledgerBucket(
            date: "2026-08-09",
            tool: "Claude Code",
            model: "claude-old"
        )
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":0,"updated":0,"unchanged":1,"ledger_version":4}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 3,
                syncedBucketHashes: [
                    currentBucket.naturalKey: currentHash,
                    staleBucket.naturalKey: "stale-hash"
                ]
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )

        _ = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )
        let ordinaryRequests = await http.requests
        XCTAssertTrue(ordinaryRequests.isEmpty)

        let state = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_100)
        )

        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let payload = try JSONDecoder().decode(
            TeamSyncDailyPayload.self,
            from: try XCTUnwrap(requests.first?.httpBody)
        )
        XCTAssertEqual(payload.buckets.count, 1)
        XCTAssertEqual(payload.buckets.first?.naturalKey, currentBucket.naturalKey)
        XCTAssertFalse(try XCTUnwrap(payload.buckets.first).deleted)
        XCTAssertEqual(
            state.syncedBucketHashes[staleBucket.naturalKey],
            "stale-hash"
        )
        XCTAssertEqual(state.syncedBucketHashes[currentBucket.naturalKey], currentHash)
        XCTAssertEqual(state.lastLedgerVersion, 4)
    }

    func testLegacyDeletedMarkerIsNeverRetransmittedByForce() async throws {
        let snapshot = authoritativeSnapshot()
        let currentBucket = try XCTUnwrap(
            TeamSyncProtocol.dailyBuckets(snapshot: snapshot).first
        )
        let currentHash = try TeamSyncProtocol.contentHash(for: currentBucket)
        let legacyDeletedBucket = ledgerBucket(
            date: "2026-08-09",
            tool: "Claude Code",
            model: "claude-old"
        )
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":0,"updated":0,"unchanged":1,"ledger_version":4}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 3,
                syncedBucketHashes: [
                    currentBucket.naturalKey: currentHash,
                    legacyDeletedBucket.naturalKey:
                        TeamSyncProtocolConfiguration.deletedLedgerMarker
                ]
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )

        let state = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )

        let requests = await http.requests
        let payload = try JSONDecoder().decode(
            TeamSyncDailyPayload.self,
            from: try XCTUnwrap(requests.first?.httpBody)
        )
        XCTAssertEqual(payload.buckets.count, 1)
        XCTAssertFalse(try XCTUnwrap(payload.buckets.first).deleted)
        XCTAssertEqual(
            state.syncedBucketHashes[legacyDeletedBucket.naturalKey],
            TeamSyncProtocolConfiguration.deletedLedgerMarker
        )
        XCTAssertEqual(state.syncedBucketHashes[currentBucket.naturalKey], currentHash)
        XCTAssertEqual(state.lastLedgerVersion, 4)
    }

    func testDeletedNaturalKeyReappearsAsNormalUpsert() async throws {
        let snapshot = authoritativeSnapshot()
        let reappearedBucket = try XCTUnwrap(
            TeamSyncProtocol.dailyBuckets(snapshot: snapshot).first
        )
        let reappearedHash = try TeamSyncProtocol.contentHash(for: reappearedBucket)
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":0,"updated":1,"unchanged":0,"ledger_version":4}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 3,
                syncedBucketHashes: [
                    reappearedBucket.naturalKey: TeamSyncProtocolConfiguration.deletedLedgerMarker
                ]
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )

        let state = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )

        let requests = await http.requests
        let payload = try JSONDecoder().decode(
            TeamSyncDailyPayload.self,
            from: try XCTUnwrap(requests.first?.httpBody)
        )
        XCTAssertEqual(payload.buckets.count, 1)
        XCTAssertFalse(try XCTUnwrap(payload.buckets.first).deleted)
        XCTAssertEqual(state.syncedBucketHashes[reappearedBucket.naturalKey], reappearedHash)
    }

    func testRetentionOnlyLedgerZeroResponseSucceedsWithoutTerminalState() async throws {
        let snapshot = authoritativeSnapshot(date: "2020-01-01")
        let bucket = try XCTUnwrap(
            TeamSyncProtocol.dailyBuckets(snapshot: snapshot).first
        )
        let expectedHash = try TeamSyncProtocol.contentHash(for: bucket)
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":0,"updated":0,"unchanged":1,"ledger_version":0}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )

        let state = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )

        XCTAssertEqual(state.lastLedgerVersion, 0)
        XCTAssertEqual(state.syncedBucketHashes[bucket.naturalKey], expectedHash)
        XCTAssertFalse(state.automaticRetryStopped)
        XCTAssertNil(state.terminalReason)
        XCTAssertNil(state.lastError)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testOpaqueStaleLedgerKeyIsRetainedWithoutDeletionOrOmission() async throws {
        let unsafeNaturalKey = "legacy-key-without-safe-components"
        let http = RecordingTeamSyncHTTPClient(responses: [])
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device",
                lastLedgerVersion: 3,
                syncedBucketHashes: [unsafeNaturalKey: "stale-hash"]
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )

        let state = try await service.synchronize(
            snapshot: .empty,
            serverURL: "https://team.example.com",
            now: Date(timeIntervalSince1970: 1_786_240_000)
        )

        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(state.syncedBucketHashes[unsafeNaturalKey], "stale-hash")
        XCTAssertEqual(state.lastLedgerVersion, 3)
        XCTAssertEqual(state.lastOmittedIncompleteBucketCount, 0)
    }

    func testNetworkFailureBacksOffThenRecoversWithoutMutatingLocalSnapshot() async throws {
        let http = OfflineThenRecoveryTeamSyncHTTPClient(
            recoveryResponse: TeamSyncHTTPResponse(
                data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":7}"#.utf8),
                statusCode: 200
            )
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )
        let snapshot = exactSnapshot()
        let snapshotBeforeSync = try canonicalJSON(snapshot)
        let failureTime = Date(timeIntervalSince1970: 1_786_240_000)

        do {
            _ = try await service.synchronize(
                snapshot: snapshot,
                serverURL: "https://team.example.com",
                now: failureTime
            )
            XCTFail("Expected the first request to fail offline")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .networkUnavailable)
        }

        let backoffState = try XCTUnwrap(stateStore.state)
        let retryAt = try XCTUnwrap(backoffState.nextAttemptAt)
        XCTAssertGreaterThan(retryAt, failureTime)
        XCTAssertEqual(backoffState.failureCount, 1)
        XCTAssertFalse(backoffState.automaticRetryStopped)
        XCTAssertNil(backoffState.lastSyncAt)
        XCTAssertTrue(backoffState.syncedBucketHashes.isEmpty)
        let failedRequestCount = await http.requestCount
        XCTAssertEqual(failedRequestCount, 1)
        XCTAssertEqual(try canonicalJSON(snapshot), snapshotBeforeSync)

        let skippedState = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            now: retryAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(skippedState.nextAttemptAt, retryAt)
        let skippedRequestCount = await http.requestCount
        XCTAssertEqual(skippedRequestCount, 1)
        XCTAssertEqual(try canonicalJSON(snapshot), snapshotBeforeSync)

        let recoveredState = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            now: retryAt
        )
        let recoveredRequestCount = await http.requestCount
        XCTAssertEqual(recoveredRequestCount, 2)
        XCTAssertEqual(recoveredState.failureCount, 0)
        XCTAssertNil(recoveredState.nextAttemptAt)
        XCTAssertNil(recoveredState.lastError)
        XCTAssertEqual(recoveredState.lastSyncAt, retryAt)
        XCTAssertEqual(recoveredState.lastLedgerVersion, 7)
        XCTAssertEqual(recoveredState.syncedBucketHashes.count, 1)
        XCTAssertEqual(try canonicalJSON(snapshot), snapshotBeforeSync)
    }

    func testRequestTimeout408BacksOffAndForceRecoversBeforeDeadline() async throws {
        try await assertTransientHTTPStatusRecovers(status: 408, forceRecovery: true)
    }

    func testTooEarly425BacksOffAndRecoversAtDeadline() async throws {
        try await assertTransientHTTPStatusRecovers(status: 425, forceRecovery: false)
    }

    func testTwoHundredNonJSONDoesNotMarkBucketSynced() async {
        await assertInvalidSuccessResponseDoesNotPersistHashes(Data("not-json".utf8))
    }

    func testTwoHundredMismatchedCountsDoesNotMarkBucketSynced() async {
        await assertInvalidSuccessResponseDoesNotPersistHashes(
            Data(#"{"created":0,"updated":0,"unchanged":0,"ledger_version":1}"#.utf8)
        )
    }

    func testCredentialRejectionsCannotBeBypassedByForce() async {
        for status in [401, 403] {
            let http = RecordingTeamSyncHTTPClient(
                responses: [TeamSyncHTTPResponse(data: Data(), statusCode: status)]
            )
            let credentials = MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            )
            let stateStore = MemoryTeamSyncStateStore(
                state: TeamSyncPersistentState(
                    serverURL: "https://team.example.com",
                    devicePublicID: "anonymous",
                    deviceID: "server-device"
                )
            )
            let service = TeamSyncService(
                httpClient: http,
                credentialStore: credentials,
                stateStore: stateStore
            )

            do {
                _ = try await service.synchronize(
                    snapshot: exactSnapshot(),
                    serverURL: "https://team.example.com",
                    force: true,
                    now: Date(timeIntervalSince1970: 1_786_240_000)
                )
                XCTFail("Expected credential rejection \(status)")
            } catch {
                XCTAssertEqual(error as? TeamSyncProtocolError, .httpStatus(status))
            }
            XCTAssertEqual(stateStore.state?.automaticRetryStopped, true)
            XCTAssertEqual(stateStore.state?.terminalReason, .credentials)
            XCTAssertNil(stateStore.state?.nextAttemptAt)

            do {
                _ = try await service.synchronize(
                    snapshot: exactSnapshot(),
                    serverURL: "https://team.example.com",
                    force: true,
                    now: Date(timeIntervalSince1970: 1_786_240_100)
                )
                XCTFail("Force bypassed credential rejection \(status)")
            } catch {
                XCTAssertEqual(error as? TeamSyncProtocolError, .reconnectRequired)
            }
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testValidation422RequiresExplicitForceThenCanRecover() async throws {
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(data: Data(), statusCode: 422),
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":2}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let credentials = MemoryTeamSyncCredentialStore(values: ["server-device": "device-secret"])
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: credentials,
            stateStore: stateStore
        )

        do {
            _ = try await service.synchronize(
                snapshot: exactSnapshot(),
                serverURL: "https://team.example.com",
                force: true,
                now: Date(timeIntervalSince1970: 1_786_240_000)
            )
            XCTFail("Expected validation rejection")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .httpStatus(422))
        }

        XCTAssertEqual(stateStore.state?.automaticRetryStopped, true)
        XCTAssertEqual(stateStore.state?.terminalReason, .requestRejected)
        XCTAssertNil(stateStore.state?.nextAttemptAt)

        do {
            _ = try await service.synchronize(
                snapshot: exactSnapshot(),
                serverURL: "https://team.example.com",
                now: Date(timeIntervalSince1970: 1_786_240_100)
            )
            XCTFail("Automatic work bypassed terminal request rejection")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .automaticRetryStopped)
        }
        var requests = await http.requests
        XCTAssertEqual(requests.count, 1)

        let recovered = try await service.synchronize(
            snapshot: exactSnapshot(),
            serverURL: "https://team.example.com",
            force: true,
            now: Date(timeIntervalSince1970: 1_786_240_200)
        )
        requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(recovered.automaticRetryStopped)
        XCTAssertNil(recovered.terminalReason)
        XCTAssertNil(recovered.lastError)
        XCTAssertEqual(recovered.failureCount, 0)
        XCTAssertEqual(recovered.lastLedgerVersion, 2)
        XCTAssertEqual(recovered.syncedBucketHashes.count, 1)
    }

    private func exactSnapshot() -> UsageSnapshot {
        UsageSnapshot(
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
    }

    private func authoritativeSnapshot(date: String = "2026-08-09") -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: nil,
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 10, cost: 0, activeDays: 1),
            daily: [
                DailyUsage(
                    date: date,
                    tools: ["Codex": 10],
                    models: ["gpt-5": 10],
                    atomicUsage: [
                        DailyAtomicUsage(
                            tool: "Codex",
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
    }

    private func ledgerBucket(
        date: String,
        tool: String = "Codex",
        model: String = "gpt-5"
    ) -> TeamSyncDailyBucket {
        TeamSyncDailyBucket(
            date: date,
            timezone: "Asia/Shanghai",
            tool: tool,
            model: model,
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 3,
            cacheWriteTokens: 4
        )
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func assertTransientHTTPStatusRecovers(
        status: Int,
        forceRecovery: Bool
    ) async throws {
        let http = RecordingTeamSyncHTTPClient(
            responses: [
                TeamSyncHTTPResponse(data: Data(), statusCode: status),
                TeamSyncHTTPResponse(
                    data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":7}"#.utf8),
                    statusCode: 200
                )
            ]
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(
                values: ["server-device": "device-secret"]
            ),
            stateStore: stateStore
        )
        let failureTime = Date(timeIntervalSince1970: 1_786_240_000)

        do {
            _ = try await service.synchronize(
                snapshot: exactSnapshot(),
                serverURL: "https://team.example.com",
                force: true,
                now: failureTime
            )
            XCTFail("Expected transient HTTP status \(status)")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .httpStatus(status))
        }

        let retryState = try XCTUnwrap(stateStore.state)
        let retryAt = try XCTUnwrap(retryState.nextAttemptAt)
        XCTAssertGreaterThan(retryAt, failureTime)
        XCTAssertFalse(retryState.automaticRetryStopped)
        XCTAssertNil(retryState.terminalReason)

        let recoveryTime: Date
        if forceRecovery {
            recoveryTime = retryAt.addingTimeInterval(-1)
        } else {
            _ = try await service.synchronize(
                snapshot: exactSnapshot(),
                serverURL: "https://team.example.com",
                now: retryAt.addingTimeInterval(-1)
            )
            let deferredRequests = await http.requests
            XCTAssertEqual(deferredRequests.count, 1)
            recoveryTime = retryAt
        }

        let recovered = try await service.synchronize(
            snapshot: exactSnapshot(),
            serverURL: "https://team.example.com",
            force: forceRecovery,
            now: recoveryTime
        )
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(recovered.automaticRetryStopped)
        XCTAssertNil(recovered.nextAttemptAt)
        XCTAssertNil(recovered.terminalReason)
        XCTAssertEqual(recovered.lastLedgerVersion, 7)
    }

    private func assertInvalidSuccessResponseDoesNotPersistHashes(_ responseData: Data) async {
        let http = RecordingTeamSyncHTTPClient(
            responses: [TeamSyncHTTPResponse(data: responseData, statusCode: 200)]
        )
        let stateStore = MemoryTeamSyncStateStore(
            state: TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "anonymous",
                deviceID: "server-device"
            )
        )
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: MemoryTeamSyncCredentialStore(values: ["server-device": "device-secret"]),
            stateStore: stateStore
        )

        do {
            _ = try await service.synchronize(
                snapshot: exactSnapshot(),
                serverURL: "https://team.example.com",
                force: true,
                now: Date(timeIntervalSince1970: 1_786_240_000)
            )
            XCTFail("Expected invalid ingest response")
        } catch {
            XCTAssertEqual(error as? TeamSyncProtocolError, .invalidIngestResponse)
        }
        XCTAssertTrue(stateStore.state?.syncedBucketHashes.isEmpty == true)
        XCTAssertNil(stateStore.state?.lastLedgerVersion)
        XCTAssertEqual(stateStore.state?.automaticRetryStopped, true)
        XCTAssertEqual(stateStore.state?.terminalReason, .requestRejected)
    }
}

private actor OfflineThenRecoveryTeamSyncHTTPClient: TeamSyncHTTPClient {
    private let recoveryResponse: TeamSyncHTTPResponse
    private(set) var requestCount = 0

    init(recoveryResponse: TeamSyncHTTPResponse) {
        self.recoveryResponse = recoveryResponse
    }

    func send(_ request: URLRequest) async throws -> TeamSyncHTTPResponse {
        requestCount += 1
        if requestCount == 1 {
            throw TeamSyncProtocolError.networkUnavailable
        }
        return recoveryResponse
    }
}

private actor RecordingTeamSyncHTTPClient: TeamSyncHTTPClient {
    private var responses: [TeamSyncHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [TeamSyncHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> TeamSyncHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw TeamSyncProtocolError.networkUnavailable
        }
        return responses.removeFirst()
    }
}

private actor SuspendedTeamSyncHTTPClient: TeamSyncHTTPClient {
    enum Mode {
        case enrollment
        case ingest
    }

    private let mode: Mode
    private var request: URLRequest?
    private var responseContinuation: CheckedContinuation<TeamSyncHTTPResponse, Error>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(mode: Mode) {
        self.mode = mode
    }

    func send(_ request: URLRequest) async throws -> TeamSyncHTTPResponse {
        self.request = request
        startContinuation?.resume()
        startContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if request != nil { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func resume() {
        guard let responseContinuation, let request else { return }
        self.responseContinuation = nil
        switch mode {
        case .enrollment:
            guard let body = request.httpBody,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let publicID = object["device_public_id"] as? String,
                  let data = try? JSONSerialization.data(
                      withJSONObject: [
                          "device_id": "server-device",
                          "device_public_id": publicID,
                          "device_secret": "fixture-device-secret-0123456789",
                          "signing_key_derivation": "sha256-tokenfleet-hmac-v1",
                      ],
                      options: [.sortedKeys]
                  )
            else {
                responseContinuation.resume(throwing: TeamSyncProtocolError.invalidEnrollmentResponse)
                return
            }
            responseContinuation.resume(
                returning: TeamSyncHTTPResponse(data: data, statusCode: 201)
            )
        case .ingest:
            responseContinuation.resume(
                returning: TeamSyncHTTPResponse(
                    data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":1}"#.utf8),
                    statusCode: 200
                )
            )
        }
    }
}

private final class MemoryTeamSyncCredentialStore: TeamSyncCredentialStoring {
    var values: [String: String]
    var isAvailable: Bool { true }

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func saveDeviceSecret(_ secret: String, deviceID: String) throws {
        values[deviceID] = secret
    }

    func loadDeviceSecret(deviceID: String) throws -> String? {
        values[deviceID]
    }

    func deleteDeviceSecret(deviceID: String) throws {
        values.removeValue(forKey: deviceID)
    }
}

private struct FailingLoadTeamSyncCredentialStore: TeamSyncCredentialStoring {
    var isAvailable: Bool { true }

    func saveDeviceSecret(_ secret: String, deviceID: String) throws {}

    func loadDeviceSecret(deviceID: String) throws -> String? {
        throw TeamSyncProtocolError.credentialStoreTemporarilyUnavailable
    }

    func deleteDeviceSecret(deviceID: String) throws {}
}

private final class MemoryTeamSyncStateStore: TeamSyncStateStoring {
    var state: TeamSyncPersistentState?

    init(state: TeamSyncPersistentState? = nil) {
        self.state = state
    }

    func load() -> TeamSyncPersistentState? {
        state
    }

    func save(_ state: TeamSyncPersistentState) throws {
        self.state = state
    }

    func delete() throws {
        state = nil
    }
}

private final class BindingMemoryCredentialStore: TeamSyncCredentialStoring {
    var isAvailable: Bool { true }
    private(set) var serverURL: String?
    private(set) var deviceID: String?
    private(set) var secret: String?

    init(serverURL: String, deviceID: String, secret: String) {
        self.serverURL = serverURL
        self.deviceID = deviceID
        self.secret = secret
    }

    func saveDeviceSecret(_ secret: String, deviceID: String) throws {
        throw TeamSyncProtocolError.secureCredentialStorageUnavailable
    }

    func loadDeviceSecret(deviceID: String) throws -> String? {
        throw TeamSyncProtocolError.secureCredentialStorageUnavailable
    }

    func deleteDeviceSecret(deviceID: String) throws {
        throw TeamSyncProtocolError.secureCredentialStorageUnavailable
    }

    func saveDeviceSecret(_ secret: String, serverURL: String, deviceID: String) throws {
        self.serverURL = serverURL
        self.deviceID = deviceID
        self.secret = secret
    }

    func loadDeviceSecret(serverURL: String, deviceID: String) throws -> String? {
        guard self.serverURL == serverURL, self.deviceID == deviceID else {
            throw TeamSyncProtocolError.credentialsUnavailable
        }
        return secret
    }

    func clearDeviceSecret(deviceID: String?) throws {
        serverURL = nil
        self.deviceID = nil
        secret = nil
    }
}

private final class ThrowingSaveTeamSyncStateStore: TeamSyncStateStoring {
    private(set) var state: TeamSyncPersistentState?

    init(state: TeamSyncPersistentState?) {
        self.state = state
    }

    func load() -> TeamSyncPersistentState? { state }

    func save(_ state: TeamSyncPersistentState) throws {
        throw TeamSyncProtocolError.stateUnavailable
    }

    func delete() throws {
        throw TeamSyncProtocolError.stateUnavailable
    }
}
