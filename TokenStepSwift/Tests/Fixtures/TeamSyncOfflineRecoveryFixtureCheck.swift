import Darwin
import Foundation

#if TOKENFLEET_IMPORT_APP_MODULE
@testable import TokenStepSwift
#endif

// The standalone fixture deliberately omits UpdateService.swift. This minimal
// definition satisfies TeamSyncService's default argument without pulling app
// update/install behavior into a non-UI protocol check.
enum UpdateService {
    static let currentVersion = "team-sync-fixture"
}

private enum FixtureFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private actor OfflineThenRecoveryHTTPClient: TeamSyncHTTPClient {
    private(set) var requestCount = 0

    func send(_ request: URLRequest) async throws -> TeamSyncHTTPResponse {
        requestCount += 1
        if requestCount == 1 {
            throw TeamSyncProtocolError.networkUnavailable
        }
        return TeamSyncHTTPResponse(
            data: Data(#"{"created":1,"updated":0,"unchanged":0,"ledger_version":7}"#.utf8),
            statusCode: 200
        )
    }
}

private final class FixtureCredentialStore: TeamSyncCredentialStoring {
    var isAvailable: Bool { true }
    private var values: [String: String]

    init(values: [String: String]) {
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

@main
struct TeamSyncOfflineRecoveryFixtureCheck {
    static func main() async {
        do {
            try requireIsolatedAppPaths()
            try await runOfflineRecoveryCheck()
            print("PASS: team sync offline backoff and recovery preserve local usage")
        } catch {
            fputs("Team sync offline recovery fixture failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func requireIsolatedAppPaths() throws {
        guard let rawRoot = ProcessInfo.processInfo.environment["TOKENFLEET_TEST_APP_SUPPORT_ROOT"],
              !rawRoot.isEmpty
        else {
            throw FixtureFailure.failed("TOKENFLEET_TEST_APP_SUPPORT_ROOT is required")
        }
        let requestedRoot = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedAppRoot = AppPaths.appSupportRoot
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try expect(resolvedAppRoot == requestedRoot, "AppPaths ignored the test override")
        try expect(
            resolvedAppRoot.path.hasPrefix(temporaryRoot.path + "/"),
            "The fixture root must be inside the system temporary directory"
        )
        try expect(
            !FileManager.default.fileExists(atPath: AppPaths.usageJSON.path),
            "The isolated fixture root must start without usage.json"
        )
    }

    private static func runOfflineRecoveryCheck() async throws {
        let snapshot = exactSnapshot()
        let snapshotBeforeSync = try canonicalJSON(snapshot)
        let stateStore = FileTeamSyncStateStore()
        try stateStore.save(
            TeamSyncPersistentState(
                serverURL: "https://team.example.com",
                devicePublicID: "fixture-public-id",
                deviceID: "fixture-server-device"
            )
        )
        let http = OfflineThenRecoveryHTTPClient()
        let service = TeamSyncService(
            httpClient: http,
            credentialStore: FixtureCredentialStore(
                values: ["fixture-server-device": "fixture-device-secret"]
            ),
            stateStore: stateStore
        )
        let failureTime = Date(timeIntervalSince1970: 1_786_240_000)

        do {
            _ = try await service.synchronize(
                snapshot: snapshot,
                serverURL: "https://team.example.com",
                now: failureTime
            )
            throw FixtureFailure.failed("The first offline request unexpectedly succeeded")
        } catch let error as TeamSyncProtocolError {
            try expect(error == .networkUnavailable, "Unexpected offline error: \(error)")
        }

        let backoffState = try unwrap(stateStore.load(), "Missing persisted backoff state")
        let retryAt = try unwrap(backoffState.nextAttemptAt, "Missing retry deadline")
        try expect(retryAt > failureTime, "Retry deadline did not move into the future")
        try expect(backoffState.failureCount == 1, "Failure count was not persisted")
        try expect(!backoffState.automaticRetryStopped, "A network failure became terminal")
        try expect(backoffState.syncedBucketHashes.isEmpty, "Offline upload wrote bucket hashes")
        try expect(backoffState.lastSyncAt == nil, "Offline upload was marked successful")
        let failedRequestCount = await http.requestCount
        try expect(failedRequestCount == 1, "Expected one failed HTTP attempt")
        let snapshotAfterFailure = try canonicalJSON(snapshot)
        try expect(
            snapshotAfterFailure == snapshotBeforeSync,
            "Offline handling mutated the local snapshot"
        )

        let skippedState = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            now: retryAt.addingTimeInterval(-1)
        )
        try expect(skippedState.nextAttemptAt == retryAt, "Backoff deadline changed while waiting")
        let skippedRequestCount = await http.requestCount
        try expect(skippedRequestCount == 1, "A request escaped before backoff elapsed")

        let recoveredState = try await service.synchronize(
            snapshot: snapshot,
            serverURL: "https://team.example.com",
            now: retryAt
        )
        let recoveredRequestCount = await http.requestCount
        try expect(recoveredRequestCount == 2, "Recovery did not retry exactly once")
        try expect(recoveredState.failureCount == 0, "Recovery did not reset failure count")
        try expect(recoveredState.nextAttemptAt == nil, "Recovery left a retry deadline")
        try expect(recoveredState.lastError == nil, "Recovery left an error")
        try expect(recoveredState.lastSyncAt == retryAt, "Recovery time was not persisted")
        try expect(recoveredState.lastLedgerVersion == 7, "Recovery ledger was not persisted")
        try expect(recoveredState.syncedBucketHashes.count == 1, "Recovered bucket was not committed")
        let snapshotAfterRecovery = try canonicalJSON(snapshot)
        try expect(
            snapshotAfterRecovery == snapshotBeforeSync,
            "Successful recovery mutated the local snapshot"
        )
        try expect(
            !FileManager.default.fileExists(atPath: AppPaths.usageJSON.path),
            "Team sync wrote to the local usage snapshot path"
        )
    }

    private static func exactSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: "2026-08-09T01:30:00Z",
            timezone: "Asia/Shanghai",
            totals: UsageTotals(tokens: 10, cost: 0, activeDays: 1),
            daily: [
                DailyUsage(
                    date: "2026-08-09",
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

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw FixtureFailure.failed(message)
        }
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw FixtureFailure.failed(message)
        }
        return value
    }
}
