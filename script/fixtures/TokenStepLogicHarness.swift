import CryptoKit
import Foundation
@testable import TokenStepSwift

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

private func runSQLiteHarness(database: URL, sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    process.standardOutput = Pipe()
    let standardError = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let data = standardError.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8) ?? "OpenCode fixture setup failed"
        throw NSError(
            domain: "TokenStepLogicHarness",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private func makePassthroughZstdDecoder(at url: URL) throws {
    try "#!/bin/sh\ncat \"$3\"\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: url.path
    )
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

        let kimiRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepKimiHarness-\(UUID().uuidString)", isDirectory: true)
        let kimiAgent = kimiRoot
            .appendingPathComponent("sessions/wd-project/session-kimi/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: kimiAgent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: kimiRoot) }
        let kimiLines = [
            #"{"type":"config.update","modelAlias":"kimi-code/kimi-k3","time":1717200000000}"#,
            #"{"type":"context.append_loop_event","event":{"type":"step.end","uuid":"step-1","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":80,"cache_creation_input_tokens":5}},"time":1717203600000}"#,
            #"{"type":"context.append_loop_event","event":{"type":"step.end","uuid":"step-2","usage":{"inputOther":50,"inputCacheRead":40,"inputCacheCreation":3,"output":10}},"time":1717207200000}"#,
            #"{"type":"usage.record","usage":{"inputOther":50,"inputCacheRead":40,"inputCacheCreation":3,"output":10},"time":1717207200000}"#
        ]
        try kimiLines.joined(separator: "\n").write(
            to: kimiAgent.appendingPathComponent("wire.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let kimiSnapshot = UsageCollector.collectUsageSnapshotForTests(
            kimiCodeRootURL: kimiRoot,
            includeExperimentalAgentSources: true
        )
        expect(kimiSnapshot.sources["Kimi"]?.records == 2, "Kimi step.end dedupe mismatch")
        expect(kimiSnapshot.totals.tokens == 308, "Kimi usage total mismatch")
        expect(kimiSnapshot.daily.first?.tools["Kimi"] == 308, "Kimi tool total mismatch")
        expect(kimiSnapshot.daily.first?.models["kimi-k3"] == 308, "Kimi model alias mismatch")

        let openCodeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepOpenCodeHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: openCodeRoot) }
        let openCodeDatabase = openCodeRoot.appendingPathComponent("opencode.db")
        try runSQLiteHarness(database: openCodeDatabase, sql: """
        create table message (
            id text primary key, session_id text not null, time_created integer not null,
            time_updated integer not null, data text not null
        );
        create table session_message (
            id text primary key, session_id text not null, time_created integer not null,
            time_updated integer not null, type text not null, data text not null
        );
        insert into message values (
            'msg-shared', 'session-open', 1717200000000, 1717200010000,
            '{"role":"assistant","modelID":"gpt-5.4","time":{"completed":1717200010000},"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":5}},"content":"must not be selected"}'
        );
        insert into session_message values (
            'msg-shared', 'session-open', 1717200000000, 1717200020000, 'assistant',
            '{"model":{"id":"claude-sonnet-5"},"time":{"completed":1717200020000},"tokens":{"input":20,"output":4,"reasoning":2,"cache":{"read":6,"write":1}},"content":"newer transition copy"}'
        );
        insert into session_message values (
            'msg-v2', 'session-open', 1717203600000, 1717203610000, 'assistant',
            '{"model":{"id":"gpt-5.4-mini"},"time":{"completed":1717203610000},"tokens":{"input":7,"output":3,"reasoning":0,"cache":{"read":0,"write":0}}}'
        );
        """)
        let openCodeSnapshot = UsageCollector.collectUsageSnapshotForTests(
            openCodeRootURL: openCodeRoot,
            includeExperimentalAgentSources: true
        )
        expect(openCodeSnapshot.sources["OpenCode"]?.records == 2, "OpenCode transition dedupe mismatch")
        expect(openCodeSnapshot.totals.tokens == 43, "OpenCode exact token total mismatch")
        expect(openCodeSnapshot.daily.first?.tools["OpenCode"] == 43, "OpenCode tool total mismatch")
        expect(openCodeSnapshot.daily.first?.models["claude-sonnet-5"] == 33, "OpenCode nested model mismatch")

        let cursorCSV = """
        Date,Cloud Agent ID,Automation ID,Kind,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        "2026-04-16T03:32:33.284Z","","","On-Demand","composer-2-fast","No","0","3189","194368","1815","199372","0.11"
        "2026-04-15T03:39:53.013Z","","","Included","claude-4.6-sonnet-medium-thinking","Yes","50000","40000","10000","3000","103000","$0.32"
        """
        let cursorRecords = CursorUsageCSVParser.parse(cursorCSV)
        expect(cursorRecords.count == 2, "Cursor CSV row count mismatch")
        expect(cursorRecords[0].exactTotalTokens == 199_372, "Cursor CSV exact component total mismatch")
        expect(cursorRecords[1].cacheWriteTokens == 10_000, "Cursor CSV cache write derivation mismatch")
        expect(cursorRecords[1].reportedTotalTokens == 103_000, "Cursor CSV reported total mismatch")

        let cursorImportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepCursorImportHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorImportRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cursorImportRoot) }
        let cursorCSVURL = cursorImportRoot.appendingPathComponent("cursor-usage.csv")
        let cursorArchiveURL = cursorImportRoot.appendingPathComponent("cursor-usage.json")
        try Data(cursorCSV.utf8).write(to: cursorCSVURL)
        let firstCursorImport = try CursorUsageImportStore.importCSV(
            from: cursorCSVURL,
            archiveURL: cursorArchiveURL
        )
        let duplicateCursorImport = try CursorUsageImportStore.importCSV(
            from: cursorCSVURL,
            archiveURL: cursorArchiveURL
        )
        expect(firstCursorImport.addedRecords == 2, "Cursor first import count mismatch")
        expect(duplicateCursorImport.addedRecords == 0, "Cursor repeated import was not deduplicated")
        let cursorSnapshot = UsageCollector.collectUsageSnapshotForTests(
            cursorUsageImportURL: cursorArchiveURL,
            includeExperimentalAgentSources: true
        )
        expect(cursorSnapshot.sources["Cursor"]?.status == "ok", "Cursor import source status mismatch")
        expect(cursorSnapshot.totals.tokens == 262_372, "Cursor imported exact token total mismatch")
        expect(abs(cursorSnapshot.totals.cost - 0.43) < 0.0001, "Cursor imported cost mismatch")

        let dirtyCursorModel = String(repeating: "e\u{301}", count: 140) + "\u{1F}invalid"
        let legacyCursorCSV = """
        \u{FEFF}Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        2025-02-01,"\(dirtyCursorModel)",1000,500,200,300,2000,$0.10
        """
        let legacyCursorCSVURL = cursorImportRoot.appendingPathComponent("legacy-cursor.csv")
        let legacyCursorArchiveURL = cursorImportRoot.appendingPathComponent("legacy-cursor.json")
        try legacyCursorCSV.write(to: legacyCursorCSVURL, atomically: true, encoding: .utf8)
        let legacyCursorImport = try CursorUsageImportStore.importCSV(
            from: legacyCursorCSVURL,
            archiveURL: legacyCursorArchiveURL
        )
        let legacyCursorSnapshot = UsageCollector.collectUsageSnapshotForTests(
            cursorUsageImportURL: legacyCursorArchiveURL,
            includeExperimentalAgentSources: true
        )
        expect(legacyCursorImport.addedRecords == 1, "Cursor BOM legacy row was rejected")
        expect(legacyCursorSnapshot.totals.tokens == 1_500, "Cursor date-only row was not collected")
        expect(legacyCursorSnapshot.daily.first?.date == "2025-02-01", "Cursor date-only day mismatch")
        let sanitizedCursorModel = legacyCursorSnapshot.daily.first?.models.keys.first ?? ""
        expect(sanitizedCursorModel.unicodeScalars.count == 128, "Cursor model key scalar limit mismatch")
        expect(!sanitizedCursorModel.contains("\u{1F}"), "Cursor model key retained natural-key separator")
        expect(
            !sanitizedCursorModel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            "Cursor model key retained control characters"
        )
        let legacyCursorBuckets = try TeamSyncProtocol.dailyBuckets(snapshot: legacyCursorSnapshot)
        expect(legacyCursorBuckets.count == 1, "Sanitized Cursor model did not build a TeamSync bucket")

        let collisionPrefix = String(repeating: "x", count: 127)
        let collisionCursorCSV = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
        2026-04-16T03:32:33Z,"\(collisionPrefix)",10,10,0,2,12,0
        2026-04-16T03:33:33Z,"\(collisionPrefix) suffix",11,11,0,4,15,0
        """
        let collisionCursorCSVURL = cursorImportRoot.appendingPathComponent("collision-cursor.csv")
        let collisionCursorArchiveURL = cursorImportRoot.appendingPathComponent("collision-cursor.json")
        try collisionCursorCSV.write(to: collisionCursorCSVURL, atomically: true, encoding: .utf8)
        _ = try CursorUsageImportStore.importCSV(
            from: collisionCursorCSVURL,
            archiveURL: collisionCursorArchiveURL
        )
        let collisionCursorSnapshot = UsageCollector.collectUsageSnapshotForTests(
            cursorUsageImportURL: collisionCursorArchiveURL,
            includeExperimentalAgentSources: true
        )
        let collisionBuckets = try TeamSyncProtocol.dailyBuckets(snapshot: collisionCursorSnapshot)
        expect(collisionCursorSnapshot.totals.tokens == 27, "Post-truncation model collision lost usage")
        expect(collisionBuckets.count == 1, "Post-truncation whitespace created duplicate buckets")
        expect(collisionBuckets.first?.model == collisionPrefix, "Post-truncation model was not trimmed")

        let legacyAgentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepLegacyAgentsHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyAgentRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyAgentRoot) }
        let minimalZCodeDatabase = legacyAgentRoot.appendingPathComponent("zcode.sqlite")
        try runSQLiteHarness(database: minimalZCodeDatabase, sql: """
        create table model_usage (
            id text primary key, session_id text not null, status text not null,
            started_at integer not null, model_id text not null,
            input_tokens integer not null default 0, output_tokens integer not null default 0
        );
        insert into model_usage values ('z-minimal', 'session-z', 'completed', 1717200000000, 'glm-5', 11, 5);
        """)
        let minimalHermesDatabase = legacyAgentRoot.appendingPathComponent("hermes.sqlite")
        try runSQLiteHarness(database: minimalHermesDatabase, sql: """
        create table sessions (
            id text primary key, started_at real not null,
            input_tokens integer default 0, output_tokens integer default 0
        );
        insert into sessions values ('h-minimal', 1717203600, 20, 6);
        """)
        let legacyAgentSnapshot = UsageCollector.collectUsageSnapshotForTests(
            zCodeDatabaseURL: minimalZCodeDatabase,
            hermesDatabaseURL: minimalHermesDatabase,
            includeExperimentalAgentSources: true
        )
        expect(legacyAgentSnapshot.sources["ZCode"]?.status == "ok", "ZCode minimal schema rejected")
        expect(legacyAgentSnapshot.sources["Hermes Agent"]?.status == "ok", "Hermes minimal schema rejected")
        expect(legacyAgentSnapshot.totals.tokens == 42, "Legacy agent schema total mismatch")

        let workBuddyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepWorkBuddyHarness-\(UUID().uuidString)", isDirectory: true)
        let workBuddyProject = workBuddyRoot.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: workBuddyProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workBuddyRoot) }
        let workBuddyLines = [
            #"{"type":"function_call","timestamp":1717200000000,"sessionId":"wb-session","providerData":{"messageId":"wb-message-1","requestModelId":"hy3","requestModelName":"wrong-request-name","model":"wrong-provider-model","rawUsage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"cache_read_input_tokens":80,"cache_creation_input_tokens":5,"prompt_tokens_details":{"cached_tokens":90}}}}"#,
            #"{"type":"message","timestamp":1717200000000,"sessionId":"wb-session","providerData":{"messageId":"wb-message-1","requestModelId":"hy3","rawUsage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"prompt_tokens_details":{"cached_tokens":90}}}}"#,
            #"{"type":"message","timestamp":1717203600000,"sessionId":"wb-session","providerData":{"conversationRequestId":"wb-request-2","rawUsage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}}"#
        ]
        try workBuddyLines.joined(separator: "\n").write(
            to: workBuddyProject.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let workBuddySnapshot = UsageCollector.collectUsageSnapshotForTests(
            workBuddyRootURLs: [workBuddyRoot],
            includeExperimentalAgentSources: true
        )
        expect(workBuddySnapshot.sources["WorkBuddy"]?.records == 2, "WorkBuddy response dedupe mismatch")
        expect(workBuddySnapshot.totals.tokens == 125, "WorkBuddy total mismatch")
        expect(workBuddySnapshot.agentWork.first?.cachedInputTokens == 90, "WorkBuddy cache mirror mismatch")
        expect(workBuddySnapshot.daily.first?.models["hy3"] == 120, "WorkBuddy request model priority regressed")
        expect(workBuddySnapshot.daily.first?.models["unknown"] == 5, "WorkBuddy missing model fallback changed")
        expect(workBuddySnapshot.daily.first?.models["auto"] == nil, "WorkBuddy emitted unstable auto model")

        let addedAgentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepAddedAgentsHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: addedAgentRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: addedAgentRoot) }

        let codeBuddyProject = addedAgentRoot.appendingPathComponent("codebuddy/projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: codeBuddyProject, withIntermediateDirectories: true)
        let codeBuddyLines = [
            #"{"type":"user","timestamp":"2024-06-01T00:59:00Z","sessionId":"cb-session","message":{"id":"cb-user","role":"user","model":"must-not-count","usage":{"input_tokens":999,"output_tokens":999}}}"#,
            #"{"type":"assistant","timestamp":"2024-06-01T01:00:00Z","sessionId":"cb-session","message":{"id":"cb-1","role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":80,"total_tokens":120}}}"#
        ]
        try codeBuddyLines.joined(separator: "\n").write(
            to: codeBuddyProject.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8
        )
        let codeBuddySnapshot = UsageCollector.collectUsageSnapshotForTests(
            codeBuddyRootURLs: [addedAgentRoot.appendingPathComponent("codebuddy")],
            includeExperimentalAgentSources: true
        )
        expect(codeBuddySnapshot.sources["CodeBuddy"]?.records == 1, "CodeBuddy transcript usage mismatch")
        expect(codeBuddySnapshot.totals.tokens == 120, "CodeBuddy exact total mismatch")
        expect(codeBuddySnapshot.daily.first?.models["must-not-count"] == nil, "CodeBuddy counted a user row")
        let disabledAgentSnapshot = UsageCollector.collectUsageSnapshotForTests(
            workBuddyRootURLs: [workBuddyRoot],
            codeBuddyRootURLs: [addedAgentRoot.appendingPathComponent("codebuddy")],
            includeExperimentalAgentSources: false
        )
        expect(disabledAgentSnapshot.sources["WorkBuddy"]?.status == "disabled", "WorkBuddy ignored disabled switch")
        expect(disabledAgentSnapshot.sources["CodeBuddy"]?.status == "disabled", "CodeBuddy ignored disabled switch")
        expect(disabledAgentSnapshot.totals.tokens == 0, "Disabled experimental sources entered totals")

        let qoderTranscript = addedAgentRoot.appendingPathComponent("qoder/project/transcript", isDirectory: true)
        try FileManager.default.createDirectory(at: qoderTranscript, withIntermediateDirectories: true)
        try #"{"type":"assistant","timestamp":1717203600000,"session_id":"qoder-session","message":{"id":"qoder-1","role":"assistant","model":"qwen3-coder","usage":{"input_tokens":70,"output_tokens":15,"cache_read_input_tokens":50}}}"#.write(
            to: qoderTranscript.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8
        )
        let qoderSnapshot = UsageCollector.collectUsageSnapshotForTests(
            qoderRootURL: addedAgentRoot.appendingPathComponent("qoder"),
            includeExperimentalAgentSources: true
        )
        expect(qoderSnapshot.sources["Qoder"]?.records == 1, "Qoder assistant usage mismatch")
        expect(qoderSnapshot.totals.tokens == 135, "Qoder exact total mismatch")

        let copilotOTelFile = addedAgentRoot.appendingPathComponent("copilot-otel.jsonl")
        let copilotChatSpan = #"{"resource":{"attributes":{"service.name":"copilot-chat"}},"name":"chat","traceId":"trace-1","spanId":"span-1","startTimeUnixNano":"1717200000000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"gpt-5","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":20,"gen_ai.usage.cache_read.input_tokens":80}}"#
        try [copilotChatSpan, copilotChatSpan].joined(separator: "\n").write(
            to: copilotOTelFile, atomically: true, encoding: .utf8
        )
        let copilotOTelSnapshot = UsageCollector.collectUsageSnapshotForTests(
            copilotOTelURLs: [copilotOTelFile],
            includeExperimentalAgentSources: true
        )
        expect(copilotOTelSnapshot.sources["Copilot OTel"]?.records == 1, "Copilot OTel span dedupe mismatch")
        expect(copilotOTelSnapshot.daily.first?.tools["Copilot Chat"] == 120, "Copilot OTel tool mismatch")

        let antigravityLogs = addedAgentRoot.appendingPathComponent("antigravity/brain/id/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: antigravityLogs, withIntermediateDirectories: true)
        let antigravityLines = [
            #"{"type":"status","timestamp":"2024-06-01T01:59:00Z","usage":{"promptTokenCount":999,"candidatesTokenCount":999,"totalTokenCount":1998}}"#,
            #"{"type":"result","timestamp":"2024-06-01T02:00:00Z","model":"gemini-3.7-flash-thinking","usageMetadata":{"promptTokenCount":90,"candidatesTokenCount":10,"thoughtsTokenCount":4,"cachedContentTokenCount":60,"totalTokenCount":104}}"#
        ]
        try antigravityLines.joined(separator: "\n").write(
            to: antigravityLogs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8
        )
        let antigravitySnapshot = UsageCollector.collectUsageSnapshotForTests(
            antigravityRootURLs: [addedAgentRoot.appendingPathComponent("antigravity")],
            includeExperimentalAgentSources: true
        )
        expect(antigravitySnapshot.sources["Antigravity"]?.records == 1, "Antigravity result usage mismatch")
        expect(antigravitySnapshot.totals.tokens == 104, "Antigravity Gemini thinking total mismatch")
        let antigravityBuckets = try TeamSyncProtocol.dailyBuckets(snapshot: antigravitySnapshot)
        expect(antigravityBuckets.count == 1, "Antigravity Gemini thinking bucket was omitted")
        expect(antigravityBuckets.first?.outputTokens == 14, "Antigravity thinking was not included in output")

        let droidProject = addedAgentRoot.appendingPathComponent("droid/project", isDirectory: true)
        try FileManager.default.createDirectory(at: droidProject, withIntermediateDirectories: true)
        try #"{"type":"result","timestamp":1717203600000,"sessionId":"droid-session","model":"claude-opus-4-8","result":{"id":"turn-1","tokenUsage":{"inputTokens":80,"outputTokens":20,"cacheReadTokens":50}}}"#.write(
            to: droidProject.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8
        )
        let droidSnapshot = UsageCollector.collectUsageSnapshotForTests(
            droidRootURL: addedAgentRoot.appendingPathComponent("droid"),
            includeExperimentalAgentSources: true
        )
        expect(droidSnapshot.sources["Droid"]?.records == 1, "Droid result usage mismatch")
        expect(droidSnapshot.totals.tokens == 150, "Droid exact total mismatch")

        let dshSession = addedAgentRoot.appendingPathComponent("dsh/workspace/session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: dshSession, withIntermediateDirectories: true)
        let dshLines = [
            #"{"type":"request/header","data":{"header":{"config":{"provider":"deepseek","model":"deepseek-v4-pro"}}}}"#,
            #"{"type":"step/start","time":1717200000000,"data":{"id":"step-1"}}"#,
            #"{"type":"assistant/chunk","time":1717203600000,"seq":2,"data":{"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":20,"cacheReadTokens":70}}}}"#,
            #"{"type":"assistant/message","time":1717203600000,"seq":3,"data":{"usage":{"inputTokens":100,"outputTokens":20,"cacheReadTokens":70}}}"#
        ]
        try dshLines.joined(separator: "\n").write(
            to: dshSession.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8
        )
        let dshSnapshot = UsageCollector.collectUsageSnapshotForTests(
            dshRootURL: addedAgentRoot.appendingPathComponent("dsh"),
            includeExperimentalAgentSources: true
        )
        expect(dshSnapshot.sources["dsh"]?.records == 1, "dsh chunk/message fallback double-counted")
        expect(dshSnapshot.totals.tokens == 190, "dsh exact total mismatch")

        let dshCompressedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepDSHCompressedHarness-\(UUID().uuidString)", isDirectory: true)
        let dshCompressedSession = dshCompressedRoot.appendingPathComponent(
            ".workspace/session-2",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dshCompressedSession, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dshCompressedRoot) }
        let dshPlainBody = [
            #"{"type":"request/header","data":{"header":{"config":{"model":"plain-must-not-count"}}}}"#,
            #"{"type":"step/start","data":{"id":"step-1"}}"#,
            #"{"type":"assistant/chunk","time":1717203600000,"seq":2,"data":{"chunk":{"type":"usage","usage":{"inputTokens":999,"outputTokens":1}}}}"#
        ].joined(separator: "\n")
        let dshCompressedBody = [
            #"{"type":"request/header","data":{"header":{"config":{"model":"compressed-model"}}}}"#,
            #"{"type":"step/start","data":{"id":"step-1"}}"#,
            #"{"type":"assistant/chunk","time":1717203600000,"seq":2,"data":{"chunk":{"type":"usage","usage":{"inputTokens":10,"outputTokens":2}}}}"#
        ].joined(separator: "\n")
        try dshPlainBody.write(
            to: dshCompressedSession.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try dshCompressedBody.write(
            to: dshCompressedSession.appendingPathComponent("session.jsonl.zstd"),
            atomically: true,
            encoding: .utf8
        )
        let fakeZstd = dshCompressedRoot.appendingPathComponent("fixture-zstd")
        try makePassthroughZstdDecoder(at: fakeZstd)
        let dshCompressedSnapshot = UsageCollector.collectUsageSnapshotForTests(
            dshRootURL: dshCompressedRoot,
            dshZstdExecutableURL: fakeZstd,
            dshDiscoverZstdDecoder: false,
            includeExperimentalAgentSources: true
        )
        expect(dshCompressedSnapshot.sources["dsh"]?.files == 1, "dsh counted plaintext/compressed twins")
        expect(dshCompressedSnapshot.sources["dsh"]?.records == 1, "dsh compressed event count mismatch")
        expect(
            dshCompressedSnapshot.totals.tokens == 12,
            "dsh compressed twin precedence mismatch: \(dshCompressedSnapshot.totals.tokens)"
        )
        expect(
            dshCompressedSnapshot.daily.first?.models["plain-must-not-count"] == nil,
            "dsh plaintext twin won over compressed data"
        )

        let dshMixedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepDSHMixedDecoderHarness-\(UUID().uuidString)", isDirectory: true)
        let dshMixedPlainSession = dshMixedRoot.appendingPathComponent(
            "workspace/session-plain",
            isDirectory: true
        )
        let dshMixedCompressedSession = dshMixedRoot.appendingPathComponent(
            "workspace/session-compressed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dshMixedPlainSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dshMixedCompressedSession, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dshMixedRoot) }
        let dshMixedPlainBody = [
            #"{"type":"request/header","data":{"header":{"config":{"model":"mixed-plain-model"}}}}"#,
            #"{"type":"step/start","data":{"id":"step-plain"}}"#,
            #"{"type":"assistant/chunk","time":1717203600000,"seq":7,"data":{"chunk":{"type":"usage","usage":{"inputTokens":7,"outputTokens":3}}}}"#
        ].joined(separator: "\n")
        try dshMixedPlainBody.write(
            to: dshMixedPlainSession.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try dshCompressedBody.write(
            to: dshMixedCompressedSession.appendingPathComponent("session.jsonl.zstd"),
            atomically: true,
            encoding: .utf8
        )
        let dshMixedSnapshot = UsageCollector.collectUsageSnapshotForTests(
            dshRootURL: dshMixedRoot,
            dshDiscoverZstdDecoder: false,
            includeExperimentalAgentSources: true
        )
        expect(
            dshMixedSnapshot.sources["dsh"]?.status == "partial_missing_decoder",
            "dsh mixed missing decoder was silently reported as complete"
        )
        expect(dshMixedSnapshot.sources["dsh"]?.records == 1, "dsh mixed plaintext record was lost")
        expect(dshMixedSnapshot.sources["dsh"]?.skippedRecords == 1, "dsh mixed skipped archive count mismatch")
        expect(dshMixedSnapshot.totals.tokens == 10, "dsh mixed readable usage mismatch")

        let dshMissingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepDSHMissingDecoderHarness-\(UUID().uuidString)", isDirectory: true)
        let dshMissingSession = dshMissingRoot.appendingPathComponent("workspace/session-3", isDirectory: true)
        try FileManager.default.createDirectory(at: dshMissingSession, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dshMissingRoot) }
        try dshCompressedBody.write(
            to: dshMissingSession.appendingPathComponent("session.jsonl.zstd"),
            atomically: true,
            encoding: .utf8
        )
        let dshMissingSnapshot = UsageCollector.collectUsageSnapshotForTests(
            dshRootURL: dshMissingRoot,
            dshDiscoverZstdDecoder: false,
            includeExperimentalAgentSources: true
        )
        expect(dshMissingSnapshot.sources["dsh"]?.status == "missing_decoder", "dsh missing decoder not surfaced")
        expect(dshMissingSnapshot.totals.tokens == 0, "dsh unreadable compressed data entered totals")

        let grokRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepGrokHarness-\(UUID().uuidString)", isDirectory: true)
        let grokSession = grokRoot.appendingPathComponent(
            "sessions/encoded-project/grok-session",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: grokSession, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: grokRoot) }
        try #"{"primaryModelId":"grok-build","contextTokensUsed":999999}"#.write(
            to: grokSession.appendingPathComponent("signals.json"),
            atomically: true,
            encoding: .utf8
        )
        let grokTurn = #"{"timestamp":1784357000,"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"prompt-1","usage":{"modelUsage":{"grok-4.5-build-free":{"inputTokens":100,"outputTokens":30,"totalTokens":130,"cachedReadTokens":20,"cacheCreationTokens":10,"reasoningTokens":10,"costUsdTicks":123000000,"modelCalls":2}}}},"_meta":{"eventId":"grok-event-1","agentTimestampMs":1784357100000}}}"#
        try [grokTurn, grokTurn].joined(separator: "\n").write(
            to: grokSession.appendingPathComponent("updates.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let grokSnapshot = UsageCollector.collectUsageSnapshotForTests(
            grokBuildRootURL: grokRoot,
            includeExperimentalAgentSources: true
        )
        expect(grokSnapshot.sources["Grok"]?.records == 1, "Grok turn usage dedupe mismatch")
        expect(grokSnapshot.totals.tokens == 130, "Grok exact usage total mismatch")
        expect(abs(grokSnapshot.totals.cost - 0.01) < 0.000_001, "Grok rounded total cost mismatch")
        expect(
            abs((grokSnapshot.daily.first?.cost ?? 0) - 0.0123) < 0.000_001,
            "Grok reported daily cost mismatch"
        )
        expect(grokSnapshot.daily.first?.models["grok-build-free"] == 130, "Grok free model canonicalization mismatch")

        let qwenRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepQwenHarness-\(UUID().uuidString)", isDirectory: true)
        let qwenUsageDirectory = qwenRoot.appendingPathComponent("usage", isDirectory: true)
        try FileManager.default.createDirectory(at: qwenUsageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: qwenRoot) }
        let qwenRequest = #"{"schemaVersion":1,"id":"qwen-request-1","timestamp":"2026-05-25T10:00:00.000Z","localDate":"2026-05-25","localMonth":"2026-05","sessionId":"qwen-session","model":"qwen3-coder-plus","authType":"qwen-oauth","source":"memory-agent","inputTokens":10,"outputTokens":20,"cachedTokens":3,"thoughtsTokens":5,"totalTokens":35,"apiDurationMs":100}"#
        try [qwenRequest, qwenRequest].joined(separator: "\n").write(
            to: qwenUsageDirectory.appendingPathComponent("token-usage-2026-05.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let qwenSnapshot = UsageCollector.collectUsageSnapshotForTests(
            qwenCodeRootURL: qwenRoot,
            includeExperimentalAgentSources: true
        )
        expect(qwenSnapshot.sources["Qwen Code"]?.records == 1, "Qwen request id dedupe mismatch")
        expect(qwenSnapshot.totals.tokens == 35, "Qwen exact usage total mismatch")
        expect(qwenSnapshot.daily.first?.models["qwen3-coder-plus"] == 35, "Qwen model mismatch")
        expect(qwenSnapshot.agentWork.first?.outputTokens == 25, "Qwen thoughts/output normalization mismatch")

        let clineRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepClineHarness-\(UUID().uuidString)", isDirectory: true)
        let clineCurrentSession = clineRoot.appendingPathComponent("sessions/session-new", isDirectory: true)
        let clineLegacyTask = clineRoot.appendingPathComponent("tasks/legacy-task", isDirectory: true)
        let clineMigratedTask = clineRoot.appendingPathComponent("tasks/session-new", isDirectory: true)
        try FileManager.default.createDirectory(at: clineCurrentSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clineLegacyTask, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clineMigratedTask, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clineRoot) }
        let clineCurrent = #"{"version":1,"sessionId":"session-new","messages":[{"id":"assistant-final","role":"assistant","ts":1717200001000,"modelInfo":{"id":"claude-sonnet-4"},"metrics":{"inputTokens":21,"outputTokens":8,"cacheReadTokens":3,"cacheWriteTokens":1,"cost":0.13}}]}"#
        try clineCurrent.write(
            to: clineCurrentSession.appendingPathComponent("session-new.messages.json"),
            atomically: true,
            encoding: .utf8
        )
        let clineLegacy = #"[{"ts":1717203600000,"type":"say","say":"api_req_started","text":"{\"model\":\"gpt-5.4\",\"tokensIn\":10}"},{"ts":1717203601000,"type":"say","say":"api_req_finished","text":"{\"tokensOut\":5,\"cacheReads\":3,\"cacheWrites\":2,\"cost\":0.02}"},{"ts":1717207200000,"type":"say","say":"deleted_api_reqs","text":"{\"modelId\":\"gpt-5.4-mini\",\"tokensIn\":4,\"tokensOut\":1,\"cacheReads\":0,\"cacheWrites\":0,\"cost\":0.01}"}]"#
        try clineLegacy.write(
            to: clineLegacyTask.appendingPathComponent("ui_messages.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"[{"ts":1717210800000,"type":"say","say":"deleted_api_reqs","text":"{\"model\":\"must-not-count\",\"tokensIn\":999,\"tokensOut\":999}"}]"#.write(
            to: clineMigratedTask.appendingPathComponent("ui_messages.json"),
            atomically: true,
            encoding: .utf8
        )
        let clineSnapshot = UsageCollector.collectUsageSnapshotForTests(
            clineRootURLs: [clineRoot],
            includeExperimentalAgentSources: true
        )
        expect(clineSnapshot.sources["Cline"]?.records == 3, "Cline exact usage record count mismatch")
        expect(clineSnapshot.totals.tokens == 54, "Cline exact usage total mismatch")
        expect(abs(clineSnapshot.totals.cost - 0.16) < 0.000_001, "Cline exact cost mismatch")
        expect(clineSnapshot.daily.first?.models["claude-sonnet-4"] == 29, "Cline v1 model usage mismatch")
        expect(clineSnapshot.daily.first?.models["gpt-5.4"] == 20, "Cline legacy merged usage mismatch")
        expect(clineSnapshot.daily.first?.models["must-not-count"] == nil, "Cline migration was double-counted")

        let copilotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepCopilotHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copilotRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copilotRoot) }
        let copilotDatabase = copilotRoot.appendingPathComponent("session-store.db")
        try runSQLiteHarness(database: copilotDatabase, sql: """
        create table assistant_usage_events (
            id integer primary key autoincrement, session_id text not null, model text not null,
            input_tokens integer, output_tokens integer, cache_read_tokens integer,
            cache_write_tokens integer, reasoning_tokens integer,
            token_details_json text, created_at text
        );
        insert into assistant_usage_events (
            session_id, model, input_tokens, output_tokens, cache_read_tokens,
            cache_write_tokens, reasoning_tokens, token_details_json, created_at
        ) values
            ('copilot-session', 'gpt-5.6-luna', 125, 7, 20, 0, 3,
             '[{"tokenType":"input","tokenCount":5},{"tokenType":"cache_read","tokenCount":20},{"tokenType":"cache_write","tokenCount":100},{"tokenType":"output","tokenCount":7}]',
             '2026-07-10T10:00:00Z'),
            ('copilot-session', 'claude-sonnet-4.6', 50, 10, 20, 5, 2,
             '{bad json', '2026-07-10T10:01:00Z');
        """)
        let copilotSnapshot = UsageCollector.collectUsageSnapshotForTests(
            copilotDatabaseURL: copilotDatabase,
            includeExperimentalAgentSources: true
        )
        expect(copilotSnapshot.sources["Copilot CLI"]?.records == 2, "Copilot CLI store record count mismatch")
        expect(copilotSnapshot.totals.tokens == 192, "Copilot CLI exact usage total mismatch")
        expect(copilotSnapshot.daily.first?.models["gpt-5.6-luna"] == 132, "Copilot CLI token details split mismatch")
        expect(copilotSnapshot.agentWork.first?.cachedInputTokens == 40, "Copilot CLI cache split mismatch")

        let copilotMixedOTel = copilotRoot.appendingPathComponent("mixed-otel.jsonl")
        let copilotOverlappingCLISpan = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-cli-overlap","spanId":"span-cli-overlap","startTimeUnixNano":"1783677600000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"copilot-session","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":20}}"#
        let copilotOldCLISpan = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-cli-old","spanId":"span-cli-old","startTimeUnixNano":"1783591200000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"copilot-session","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":30,"gen_ai.usage.output_tokens":5}}"#
        let copilotOtherSessionSpan = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-cli-other","spanId":"span-cli-other","startTimeUnixNano":"1783677600000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"other-session","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":40,"gen_ai.usage.output_tokens":6}}"#
        let copilotUnmatchedSameDaySpan = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-cli-unmatched-current","spanId":"span-cli-unmatched-current","startTimeUnixNano":"1783677660000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":200,"gen_ai.usage.output_tokens":20}}"#
        let copilotUnmatchedOlderSpan = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-cli-unmatched-old","spanId":"span-cli-unmatched-old","startTimeUnixNano":"1783591260000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":9,"gen_ai.usage.output_tokens":2}}"#
        try [
            copilotChatSpan,
            copilotOverlappingCLISpan,
            copilotOldCLISpan,
            copilotOtherSessionSpan,
            copilotUnmatchedSameDaySpan,
            copilotUnmatchedOlderSpan
        ].joined(separator: "\n").write(
            to: copilotMixedOTel, atomically: true, encoding: .utf8
        )
        let copilotMixedSnapshot = UsageCollector.collectUsageSnapshotForTests(
            copilotDatabaseURL: copilotDatabase,
            copilotOTelURLs: [copilotMixedOTel],
            includeExperimentalAgentSources: true
        )
        expect(copilotMixedSnapshot.sources["Copilot OTel"]?.records == 4, "Copilot store/OTel overlap scope mismatch")
        expect(copilotMixedSnapshot.sources["Copilot OTel"]?.skippedRecords == 2, "Copilot CLI OTel duplicate was not skipped")
        expect(copilotMixedSnapshot.totals.tokens == 404, "Copilot older OTel history was discarded")

        let piRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepPiHarness-\(UUID().uuidString)", isDirectory: true)
        let piProjectA = piRoot.appendingPathComponent("project-a", isDirectory: true)
        let piProjectB = piRoot.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: piProjectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: piProjectB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: piRoot) }
        let piHeader = #"{"type":"session","version":3,"id":"pi-session","timestamp":"2026-07-10T10:00:00Z","cwd":"/tmp/project"}"#
        let piAssistant = #"{"type":"message","id":"pi-message-1","timestamp":"2026-07-10T10:01:00Z","message":{"role":"assistant","provider":"minimax","model":"minimax-m3","timestamp":1783677660000,"usage":{"input":10,"output":5,"cacheRead":20,"cacheWrite":3,"totalTokens":38,"cost":{"total":0.02}},"content":[{"type":"toolCall","name":"read"}]}}"#
        let piBody = [piHeader, piAssistant].joined(separator: "\n") + "\n"
        try piBody.write(to: piProjectA.appendingPathComponent("pi-session.jsonl"), atomically: true, encoding: .utf8)
        try piBody.write(to: piProjectB.appendingPathComponent("copied-session.jsonl"), atomically: true, encoding: .utf8)
        let piSnapshot = UsageCollector.collectUsageSnapshotForTests(
            piSessionsRootURL: piRoot,
            includeExperimentalAgentSources: true
        )
        expect(piSnapshot.sources["Pi"]?.records == 1, "Pi session copy dedupe mismatch")
        expect(piSnapshot.totals.tokens == 38, "Pi exact usage total mismatch")
        expect(piSnapshot.daily.first?.models["minimax-m3"] == 38, "Pi model usage mismatch")
        expect(piSnapshot.agentWork.first?.toolCallCount == 1, "Pi tool-call count mismatch")

        let openClawRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepOpenClawHarness-\(UUID().uuidString)", isDirectory: true)
        let openClawAgent = openClawRoot.appendingPathComponent("agents/main/agent", isDirectory: true)
        let openClawSessions = openClawRoot.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: openClawAgent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openClawSessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: openClawRoot) }
        let openClawDatabase = openClawAgent.appendingPathComponent("openclaw-agent.sqlite")
        let openClawCurrent = #"{"type":"message","id":"openclaw-current","timestamp":"2026-07-10T10:00:00Z","message":{"role":"assistant","model":"MiniMax-M3","timestamp":1783677600000,"usage":{"input":10,"output":5,"cacheRead":10,"cacheWrite":5,"totalTokens":30,"cost":{"total":0.04}}}}"#
        try runSQLiteHarness(database: openClawDatabase, sql: """
        create table transcript_events (
            session_id text not null, seq integer not null, event_json text not null,
            created_at integer not null, primary key (session_id, seq)
        );
        insert into transcript_events values (
            'openclaw-session', 1, '\(openClawCurrent.replacingOccurrences(of: "'", with: "''"))', 1783677600000
        );
        """)
        let openClawHeader = #"{"type":"session","id":"openclaw-session","timestamp":"2026-07-10T09:59:00Z"}"#
        try [openClawHeader, openClawCurrent].joined(separator: "\n").appending("\n").write(
            to: openClawSessions.appendingPathComponent("openclaw-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let openClawArchived = #"{"type":"message","id":"openclaw-archived","timestamp":"2026-07-10T10:02:00Z","message":{"role":"assistant","model":"qwen3-coder","timestamp":1783677720000,"usage":{"input":3,"output":2,"cacheRead":4,"cacheWrite":1,"totalTokens":10,"cost":{"total":0.01}}}}"#
        try [openClawHeader, openClawArchived].joined(separator: "\n").appending("\n").write(
            to: openClawSessions.appendingPathComponent("openclaw-session.jsonl.deleted.1783677800000Z"),
            atomically: true,
            encoding: .utf8
        )
        let openClawSnapshot = UsageCollector.collectUsageSnapshotForTests(
            openClawRootURLs: [openClawRoot],
            includeExperimentalAgentSources: true
        )
        expect(openClawSnapshot.sources["OpenClaw"]?.records == 2, "OpenClaw SQLite/JSONL dedupe mismatch")
        expect(openClawSnapshot.totals.tokens == 40, "OpenClaw exact usage total mismatch")
        expect(abs(openClawSnapshot.totals.cost - 0.05) < 0.000_001, "OpenClaw exact cost mismatch")
        expect(openClawSnapshot.daily.first?.models["MiniMax-M3"] == 30, "OpenClaw model usage mismatch")

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
