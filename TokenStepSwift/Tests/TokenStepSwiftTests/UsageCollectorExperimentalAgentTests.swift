import Foundation
import XCTest
@testable import TokenStepSwift

final class UsageCollectorExperimentalAgentTests: XCTestCase {
    func testExperimentalSourcesAreDisabledByDefault() throws {
        let zCodeDB = try makeZCodeDatabase(rowsSQL: """
        insert into model_usage (
            id, logical_request_id, session_id, query_source, provider_id, model_id, status, started_at,
            input_tokens, output_tokens, reasoning_tokens, cache_creation_input_tokens, cache_read_input_tokens,
            computed_total_tokens, tool_call_count
        ) values
            ('z-1', 'logical-1', 'session-z', 'cli', 'openai', 'gpt-5', 'completed', 1717200000000,
             10, 20, 5, 3, 2, 40, 4);
        """)
        let hermesDB = try makeHermesDatabase(rowsSQL: """
        insert into sessions (
            id, source, model, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
            reasoning_tokens, tool_call_count, api_call_count, actual_cost_usd, estimated_cost_usd, cost_status
        ) values
            ('h-1', 'cli', 'gpt-5', 1717203600, 10, 15, 5, 2, 3, 6, 2, 0.42, 0.30, 'included');
        """)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            zCodeDatabaseURL: zCodeDB,
            hermesDatabaseURL: hermesDB
        )

        XCTAssertEqual(snapshot.sources["ZCode"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Hermes Agent"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["CodeBuddy"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Qoder"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Kimi"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["OpenCode"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Grok"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Qwen Code"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Cursor"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Cline"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Copilot CLI"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Copilot OTel"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Antigravity"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Droid"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["dsh"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["Pi"]?.status, "disabled")
        XCTAssertEqual(snapshot.sources["OpenClaw"]?.status, "disabled")
        XCTAssertEqual(snapshot.totals.tokens, 0)
        XCTAssertTrue(snapshot.agentWork.isEmpty)
    }

    func testZCodeCollectorUsesCompletedModelUsageRowsOnly() throws {
        let database = try makeZCodeDatabase(rowsSQL: """
        insert into model_usage (
            id, logical_request_id, session_id, query_source, provider_id, model_id, status, started_at,
            input_tokens, output_tokens, reasoning_tokens, cache_creation_input_tokens, cache_read_input_tokens,
            computed_total_tokens, tool_call_count
        ) values
            ('z-ok', 'logical-1', 'session-z', 'cli', 'openai', 'gpt-5', 'completed', 1717200000000,
             30, 10, 5, 3, 2, 0, 4),
            ('z-error', 'logical-2', 'session-z', 'cli', 'openai', 'gpt-5', 'error', 1717203600000,
             100, 100, 0, 0, 0, 200, 99),
            ('z-cancel', 'logical-3', 'session-z', 'cli', 'openai', 'gpt-5', 'cancelled', 1717207200000,
             100, 100, 0, 0, 0, 200, 99);
        """)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            zCodeDatabaseURL: database,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["ZCode"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["ZCode"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 40)
        XCTAssertEqual(snapshot.daily.first?.tools["ZCode"], 40)
        XCTAssertEqual(snapshot.daily.first?.models["gpt-5"], 40)

        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.totalTokens, 40)
        XCTAssertEqual(work.modelRequestCount, 1)
        XCTAssertEqual(work.toolCallCount, 4)
        XCTAssertEqual(work.sources.first?.source, "ZCode")
        XCTAssertEqual(work.sources.first?.tokens, 40)
        XCTAssertEqual(work.hourlyBuckets.count, 24)
        XCTAssertEqual(work.hourlyBuckets.map(\.totalTokens).reduce(0, +) + work.unbucketedTokens, 40)
        XCTAssertEqual(try XCTUnwrap(work.cacheHitRate), 2.0 / 30.0, accuracy: 0.000_001)
    }

    func testZCodeCollectorRejectsAmbiguousReasoningTotals() throws {
        let database = try makeZCodeDatabase(rowsSQL: """
        insert into model_usage (
            id, logical_request_id, session_id, query_source, provider_id, model_id, status, started_at,
            input_tokens, output_tokens, reasoning_tokens, cache_creation_input_tokens, cache_read_input_tokens,
            provider_total_tokens, computed_total_tokens, tool_call_count
        ) values
            ('z-ambiguous', 'logical-1', 'session-z', 'cli', 'openai', 'gpt-5', 'completed',
             1717200000000, 30, 10, 5, 3, 2, 40, 45, 4);
        """)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            zCodeDatabaseURL: database,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["ZCode"]?.status, "missing_valid_rows")
        XCTAssertEqual(snapshot.sources["ZCode"]?.records, 0)
        XCTAssertEqual(snapshot.totals.tokens, 0)
        XCTAssertTrue(snapshot.agentWork.isEmpty)
    }

    func testZCodeCollectorAcceptsOlderMinimalSchema() throws {
        let database = try fixtureDatabase(prefix: "TokenStepZCodeMinimal")
        try runSQLite(database: database, sql: """
        create table model_usage (
            id text primary key,
            session_id text not null,
            status text not null,
            started_at integer not null,
            model_id text not null,
            input_tokens integer not null default 0,
            output_tokens integer not null default 0
        );
        insert into model_usage values
            ('z-minimal', 'session-old-z', 'completed', 1717200000000, 'glm-5', 11, 5);
        """)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            zCodeDatabaseURL: database,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["ZCode"]?.status, "ok")
        XCTAssertEqual(snapshot.totals.tokens, 16)
        XCTAssertEqual(snapshot.daily.first?.models["glm-5"], 16)
    }

    func testHermesCollectorReadsSessionUsageWithoutMessageContent() throws {
        let database = try makeHermesDatabase(rowsSQL: """
        insert into sessions (
            id, source, model, started_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
            reasoning_tokens, tool_call_count, api_call_count, actual_cost_usd, estimated_cost_usd, cost_status
        ) values
            ('h-ok', 'feishu', 'gpt-5.5', 1717203600.5, 10, 15, 5, 2, 3, 6, 2, 0.42, 0.30, 'included'),
            ('h-zero', 'cli', 'gpt-5.5', 1717207200, 0, 0, 0, 0, 0, 3, 1, 9.99, 9.99, 'included');
        """)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            hermesDatabaseURL: database,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Hermes Agent"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Hermes Agent"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 32)
        XCTAssertEqual(snapshot.totals.cost, 0.42)
        XCTAssertEqual(snapshot.daily.first?.tools["Hermes Agent"], 32)
        XCTAssertEqual(snapshot.daily.first?.models["gpt-5.5"], 32)

        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.modelRequestCount, 2)
        XCTAssertEqual(work.toolCallCount, 6)
        XCTAssertEqual(work.sources.first?.source, "Hermes Agent")
        XCTAssertEqual(work.inputTokens, 17)
        XCTAssertEqual(work.cachedInputTokens, 5)
        XCTAssertEqual(work.outputTokens, 15)
        XCTAssertEqual(try XCTUnwrap(work.cacheHitRate), 5.0 / 17.0, accuracy: 0.000_001)
    }

    func testHermesCollectorAcceptsOlderMinimalSchema() throws {
        let database = try fixtureDatabase(prefix: "TokenStepHermesMinimal")
        try runSQLite(database: database, sql: """
        create table sessions (
            id text primary key,
            started_at real not null,
            input_tokens integer default 0,
            output_tokens integer default 0
        );
        insert into sessions values ('h-minimal', 1717203600, 20, 6);
        """)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            hermesDatabaseURL: database,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Hermes Agent"]?.status, "ok")
        XCTAssertEqual(snapshot.totals.tokens, 26)
        XCTAssertEqual(snapshot.daily.first?.models["unknown"], 26)
    }

    func testWorkBuddyDiscoveryDoesNotEnterTotals() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepWorkBuddy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            workBuddyRootURLs: [directory],
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["WorkBuddy"]?.status, "discovered_no_usage")
        XCTAssertEqual(snapshot.sources["WorkBuddy"]?.records, 0)
        XCTAssertEqual(snapshot.totals.tokens, 0)
        XCTAssertTrue(snapshot.daily.isEmpty)
        XCTAssertTrue(snapshot.agentWork.isEmpty)
    }

    func testWorkBuddyCollectorDoesNotOpenMixedContentLogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepWorkBuddy-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let lines = [
            """
            {"type":"function_call","timestamp":1717200000000,"sessionId":"wb-session","message":{"usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120,"cache_read_input_tokens":80,"cache_creation_input_tokens":5,"prompt_tokens_details":{"cached_tokens":90}}},"providerData":{"requestModelId":"hy3","requestModelName":"wrong-request-name","model":"wrong-provider-model","messageId":"wb-message-1","conversationRequestId":"wb-request-1","toolResult":{"content":"must not be parsed"}}}
            """,
            """
            {"type":"message","timestamp":1717203600000,"sessionId":"wb-session","providerData":{"requestModelId":"kimi-k3-1","conversationRequestId":"wb-request-2","rawUsage":{"prompt_tokens":50,"completion_tokens":10,"total_tokens":60,"prompt_cache_hit_tokens":40,"completion_thinking_tokens":3,"completion_tokens_details":{"reasoning_tokens":4}}}}
            """,
            """
            {"type":"message","timestamp":1717200000000,"sessionId":"wb-session","providerData":{"requestModelId":"hy3","messageId":"wb-message-1","rawUsage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"prompt_tokens_details":{"cached_tokens":90},"cache_creation_input_tokens":5}}}
            """,
            """
            {"type":"message","timestamp":1717207200000,"sessionId":"wb-session","message":{"content":"no usage row"}}
            """,
            """
            {"type":"message","timestamp":1717210800000,"sessionId":"wb-session","providerData":{"conversationRequestId":"wb-request-3","rawUsage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}}
            """
        ]
        try lines.joined(separator: "\n").write(
            to: project.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            workBuddyRootURLs: [root],
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["WorkBuddy"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["WorkBuddy"]?.files, 1)
        XCTAssertEqual(snapshot.sources["WorkBuddy"]?.records, 3)
        XCTAssertEqual(snapshot.totals.tokens, 185)
        XCTAssertEqual(snapshot.daily.first?.tools["WorkBuddy"], 185)
        XCTAssertEqual(snapshot.daily.first?.models["hy3"], 120)
        XCTAssertEqual(snapshot.daily.first?.models["kimi-k3-1"], 60)
        XCTAssertEqual(snapshot.daily.first?.models["unknown"], 5)
        XCTAssertNil(snapshot.daily.first?.models["wrong-provider-model"])
        XCTAssertNil(snapshot.daily.first?.models["auto"])

        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.totalTokens, 185)
        XCTAssertEqual(work.inputTokens, 153)
        XCTAssertEqual(work.cachedInputTokens, 130)
        XCTAssertEqual(work.outputTokens, 32)
        XCTAssertEqual(work.modelRequestCount, 3)
        XCTAssertEqual(work.toolCallCount, 1)
        XCTAssertEqual(work.sources.first?.source, "WorkBuddy")
    }

    func testCodeBuddyCollectorReadsClaudeShapedTranscriptUsage() throws {
        let root = try temporaryDirectory(prefix: "TokenStepCodeBuddy")
        let project = root.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","timestamp":"2024-06-01T00:59:00Z","sessionId":"cb-session","message":{"id":"cb-user","role":"user","model":"must-not-count","usage":{"input_tokens":999,"output_tokens":999}}}"#,
            #"{"type":"assistant","timestamp":"2024-06-01T01:00:00Z","sessionId":"cb-session","message":{"id":"cb-response","role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":80,"total_tokens":120}}}"#
        ]
        try lines.joined(separator: "\n")
            .write(to: project.appendingPathComponent("cb-session.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            codeBuddyRootURLs: [root],
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["CodeBuddy"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["CodeBuddy"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 120)
        XCTAssertEqual(snapshot.daily.first?.tools["CodeBuddy"], 120)
        XCTAssertEqual(snapshot.daily.first?.models["claude-sonnet-4-6"], 120)
        XCTAssertNil(snapshot.daily.first?.models["must-not-count"])
    }

    func testQoderCollectorCountsAssistantUsageOnly() throws {
        let root = try temporaryDirectory(prefix: "TokenStepQoder")
        let transcript = root.appendingPathComponent("project/transcript", isDirectory: true)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","timestamp":1717200000000,"usage":{"input_tokens":999,"output_tokens":999}}"#,
            #"{"type":"assistant","timestamp":1717203600000,"session_id":"qoder-session","message":{"id":"qoder-1","role":"assistant","model":"qwen3-coder","usage":{"input_tokens":70,"output_tokens":15,"cache_creation_input_tokens":5,"cache_read_input_tokens":50}}}"#
        ]
        try lines.joined(separator: "\n").write(
            to: transcript.appendingPathComponent("qoder-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            qoderRootURL: root,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Qoder"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Qoder"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 140)
        XCTAssertEqual(snapshot.daily.first?.tools["Qoder"], 140)
    }

    func testCopilotOTelCountsChatSpansOnlyAndDeduplicatesSpanIDs() throws {
        let root = try temporaryDirectory(prefix: "TokenStepCopilotOTel")
        let file = root.appendingPathComponent("copilot-otel.jsonl")
        let chat = #"{"resource":{"attributes":{"service.name":"copilot-chat"}},"name":"chat","traceId":"trace-1","spanId":"span-1","startTimeUnixNano":"1717200000000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"gpt-5","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":20,"gen_ai.usage.cache_read.input_tokens":80,"gen_ai.usage.reasoning.output_tokens":4}}"#
        let rootSpan = #"{"resource":{"attributes":{"service.name":"copilot-chat"}},"name":"invoke_agent","traceId":"trace-1","spanId":"root-1","startTimeUnixNano":"1717200000000000000","attributes":{"gen_ai.operation.name":"invoke_agent","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":20}}"#
        try [chat, chat, rootSpan].joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            copilotOTelURLs: [file],
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Copilot OTel"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Copilot OTel"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 120)
        XCTAssertEqual(snapshot.daily.first?.tools["Copilot Chat"], 120)
    }

    func testAntigravityCollectorReadsTranscriptResultUsage() throws {
        let root = try temporaryDirectory(prefix: "TokenStepAntigravity")
        let logs = root.appendingPathComponent("brain/session/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"status","timestamp":"2024-06-01T01:59:00Z","usage":{"promptTokenCount":999,"candidatesTokenCount":999,"totalTokenCount":1998}}"#,
            #"{"type":"result","timestamp":"2024-06-01T02:00:00Z","session_id":"agy-session","model":"gemini-3.7-flash-thinking","usageMetadata":{"promptTokenCount":90,"candidatesTokenCount":10,"thoughtsTokenCount":4,"cachedContentTokenCount":60,"totalTokenCount":104}}"#
        ]
        try lines.joined(separator: "\n")
            .write(to: logs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            antigravityRootURLs: [root],
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Antigravity"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Antigravity"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 104)
        XCTAssertEqual(snapshot.daily.first?.tools["Antigravity"], 104)
        let buckets = try TeamSyncProtocol.dailyBuckets(snapshot: snapshot)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets.first?.outputTokens, 14)
    }

    func testDroidCollectorIgnoresCumulativeUpdatesAndReadsResultUsage() throws {
        let root = try temporaryDirectory(prefix: "TokenStepDroid")
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"token_usage_update","timestamp":1717200000000,"tokenUsage":{"inputTokens":999,"outputTokens":999}}"#,
            #"{"type":"result","timestamp":1717203600000,"sessionId":"droid-session","model":"claude-opus-4-8","result":{"id":"turn-1","tokenUsage":{"inputTokens":80,"outputTokens":20,"cacheReadTokens":50,"cacheCreationTokens":5,"thinkingTokens":3}}}"#
        ]
        try lines.joined(separator: "\n").write(
            to: project.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            droidRootURL: root,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Droid"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Droid"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 155)
        XCTAssertEqual(snapshot.daily.first?.tools["Droid"], 155)
    }

    func testDSHCollectorPrefersUsageChunkOverMessageFallback() throws {
        let root = try temporaryDirectory(prefix: "TokenStepDSH")
        let session = root.appendingPathComponent("workspace/session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"request/header","data":{"header":{"config":{"provider":"deepseek","model":"deepseek-v4-pro"}}}}"#,
            #"{"type":"step/start","time":1717200000000,"data":{"id":"step-1"}}"#,
            #"{"type":"assistant/chunk","time":1717203600000,"seq":2,"data":{"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":20,"cacheReadTokens":70}}}}"#,
            #"{"type":"assistant/message","time":1717203600000,"seq":3,"data":{"usage":{"inputTokens":100,"outputTokens":20,"cacheReadTokens":70}}}"#,
            #"{"type":"step/start","time":1717207200000,"data":{"id":"step-2"}}"#,
            #"{"type":"assistant/message","time":1717210800000,"seq":5,"data":{"usage":{"inputTokens":40,"outputTokens":10,"cacheReadTokens":20}}}"#
        ]
        try lines.joined(separator: "\n").write(
            to: session.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            dshRootURL: root,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["dsh"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["dsh"]?.records, 2)
        XCTAssertEqual(snapshot.totals.tokens, 260)
        XCTAssertEqual(snapshot.daily.first?.tools["dsh"], 260)
    }

    func testDSHCollectorPrefersCompressedTwinAndReportsMissingDecoder() throws {
        let root = try temporaryDirectory(prefix: "TokenStepDSHCompressed")
        let session = root.appendingPathComponent(".workspace/session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let plain = [
            #"{"type":"request/header","data":{"header":{"config":{"model":"plain-must-not-count"}}}}"#,
            #"{"type":"step/start","data":{"id":"step-1"}}"#,
            #"{"type":"assistant/chunk","time":1717203600000,"seq":2,"data":{"chunk":{"type":"usage","usage":{"inputTokens":999,"outputTokens":1}}}}"#
        ].joined(separator: "\n")
        let compressedFixture = [
            #"{"type":"request/header","data":{"header":{"config":{"model":"compressed-model"}}}}"#,
            #"{"type":"step/start","data":{"id":"step-1"}}"#,
            #"{"type":"assistant/chunk","time":1717203600000,"seq":2,"data":{"chunk":{"type":"usage","usage":{"inputTokens":10,"outputTokens":2}}}}"#
        ].joined(separator: "\n")
        try plain.write(to: session.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        try compressedFixture.write(
            to: session.appendingPathComponent("session.jsonl.zstd"),
            atomically: true,
            encoding: .utf8
        )
        let decoder = try makePassthroughZstdDecoder(in: root)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            dshRootURL: root,
            dshZstdExecutableURL: decoder,
            dshDiscoverZstdDecoder: false,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["dsh"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["dsh"]?.files, 1)
        XCTAssertEqual(snapshot.sources["dsh"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 12)
        XCTAssertEqual(snapshot.daily.first?.models["compressed-model"], 12)
        XCTAssertNil(snapshot.daily.first?.models["plain-must-not-count"])

        let missingRoot = try temporaryDirectory(prefix: "TokenStepDSHMissingDecoder")
        let missingSession = missingRoot.appendingPathComponent("workspace/session-2", isDirectory: true)
        try FileManager.default.createDirectory(at: missingSession, withIntermediateDirectories: true)
        try compressedFixture.write(
            to: missingSession.appendingPathComponent("session.jsonl.zstd"),
            atomically: true,
            encoding: .utf8
        )
        let missingSnapshot = UsageCollector.collectUsageSnapshotForTests(
            dshRootURL: missingRoot,
            dshDiscoverZstdDecoder: false,
            includeExperimentalAgentSources: true
        )
        XCTAssertEqual(missingSnapshot.sources["dsh"]?.status, "missing_decoder")
        XCTAssertEqual(missingSnapshot.sources["dsh"]?.records, 0)
        XCTAssertEqual(missingSnapshot.totals.tokens, 0)

        let mixedRoot = try temporaryDirectory(prefix: "TokenStepDSHMixedDecoder")
        let mixedPlainSession = mixedRoot.appendingPathComponent("workspace/plain", isDirectory: true)
        let mixedCompressedSession = mixedRoot.appendingPathComponent("workspace/compressed", isDirectory: true)
        try FileManager.default.createDirectory(at: mixedPlainSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mixedCompressedSession, withIntermediateDirectories: true)
        let mixedPlain = [
            #"{"type":"request/header","data":{"header":{"config":{"model":"mixed-plain-model"}}}}"#,
            #"{"type":"step/start","data":{"id":"step-plain"}}"#,
            #"{"type":"assistant/chunk","time":1717203600000,"seq":7,"data":{"chunk":{"type":"usage","usage":{"inputTokens":7,"outputTokens":3}}}}"#
        ].joined(separator: "\n")
        try mixedPlain.write(
            to: mixedPlainSession.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try compressedFixture.write(
            to: mixedCompressedSession.appendingPathComponent("session.jsonl.zstd"),
            atomically: true,
            encoding: .utf8
        )
        let mixedSnapshot = UsageCollector.collectUsageSnapshotForTests(
            dshRootURL: mixedRoot,
            dshDiscoverZstdDecoder: false,
            includeExperimentalAgentSources: true
        )
        XCTAssertEqual(mixedSnapshot.sources["dsh"]?.status, "partial_missing_decoder")
        XCTAssertEqual(mixedSnapshot.sources["dsh"]?.records, 1)
        XCTAssertEqual(mixedSnapshot.sources["dsh"]?.skippedRecords, 1)
        XCTAssertEqual(mixedSnapshot.totals.tokens, 10)
    }

    func testKimiCodeCollectorReadsStepEndUsageWithoutMessageContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepKimiCode-\(UUID().uuidString)", isDirectory: true)
        let agent = root
            .appendingPathComponent("sessions/wd-project/session-kimi/agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let lines = [
            #"{"type":"config.update","modelAlias":"kimi-code/kimi-k3","time":1717200000000}"#,
            #"{"type":"context.append_loop_event","event":{"type":"step.end","uuid":"step-1","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":80,"cache_creation_input_tokens":5}},"time":1717203600000,"content":"must not be parsed"}"#,
            #"{"type":"context.append_loop_event","event":{"type":"step.end","uuid":"step-2","usage":{"inputOther":50,"inputCacheRead":40,"inputCacheCreation":3,"output":10}},"time":1717207200000}"#,
            #"{"type":"usage.record","usage":{"inputOther":50,"inputCacheRead":40,"inputCacheCreation":3,"output":10},"time":1717207200000}"#
        ]
        try lines.joined(separator: "\n").write(
            to: agent.appendingPathComponent("wire.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            kimiCodeRootURL: root,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Kimi"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Kimi"]?.files, 1)
        XCTAssertEqual(snapshot.sources["Kimi"]?.records, 2)
        XCTAssertEqual(snapshot.totals.tokens, 308)
        XCTAssertEqual(snapshot.daily.first?.tools["Kimi"], 308)
        XCTAssertEqual(snapshot.daily.first?.models["kimi-k3"], 308)

        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.totalTokens, 308)
        XCTAssertEqual(work.inputTokens, 278)
        XCTAssertEqual(work.cachedInputTokens, 120)
        XCTAssertEqual(work.outputTokens, 30)
        XCTAssertEqual(work.modelRequestCount, 2)
        XCTAssertEqual(work.sources.first?.source, "Kimi")
    }

    func testOpenCodeCollectorReadsV1AndV2UsageAndDeduplicatesTransitionRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepOpenCode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let database = root.appendingPathComponent("opencode.db")
        try runSQLite(database: database, sql: """
        create table message (
            id text primary key,
            session_id text not null,
            time_created integer not null,
            time_updated integer not null,
            data text not null
        );
        create table session_message (
            id text primary key,
            session_id text not null,
            time_created integer not null,
            time_updated integer not null,
            type text not null,
            data text not null
        );
        insert into message values (
            'msg-shared', 'session-open', 1717200000000, 1717200010000,
            '{"role":"assistant","modelID":"gpt-5.4","time":{"created":1717200000000,"completed":1717200010000},"tokens":{"input":10,"output":2,"reasoning":1,"cache":{"read":3,"write":5}},"content":"must not be selected"}'
        );
        insert into session_message values (
            'msg-shared', 'session-open', 1717200000000, 1717200020000, 'assistant',
            '{"role":"assistant","model":{"id":"claude-sonnet-5","providerID":"anthropic"},"time":{"created":1717200000000,"completed":1717200020000},"tokens":{"input":20,"output":4,"reasoning":2,"cache":{"read":6,"write":1}},"content":"newer transition copy"}'
        );
        insert into session_message values (
            'msg-v2', 'session-open', 1717203600000, 1717203610000, 'assistant',
            '{"role":"assistant","model":{"id":"gpt-5.4-mini","providerID":"openai"},"time":{"created":1717203600000,"completed":1717203610000},"tokens":{"input":7,"output":3,"reasoning":0,"cache":{"read":0,"write":0}},"content":"must not be selected"}'
        );
        """)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            openCodeRootURL: root,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["OpenCode"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["OpenCode"]?.files, 1)
        XCTAssertEqual(snapshot.sources["OpenCode"]?.records, 2)
        XCTAssertEqual(snapshot.totals.tokens, 43)
        XCTAssertEqual(snapshot.daily.first?.tools["OpenCode"], 43)
        XCTAssertEqual(snapshot.daily.first?.models["claude-sonnet-5"], 33)
        XCTAssertEqual(snapshot.daily.first?.models["gpt-5.4-mini"], 10)

        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.totalTokens, 43)
        XCTAssertEqual(work.inputTokens, 34)
        XCTAssertEqual(work.cachedInputTokens, 6)
        XCTAssertEqual(work.outputTokens, 9)
        XCTAssertEqual(work.modelRequestCount, 2)
        XCTAssertEqual(work.sources.first?.source, "OpenCode")
    }

    func testGrokBuildCollectorReadsExactTurnUsageWithoutContextEstimate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepGrok-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent(
            "sessions/encoded-project/grok-session/",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        try #"{"primaryModelId":"grok-build","contextTokensUsed":999999}"#.write(
            to: session.appendingPathComponent("signals.json"),
            atomically: true,
            encoding: .utf8
        )
        let turn = #"{"timestamp":1784357000,"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"prompt-1","usage":{"inputTokens":100,"outputTokens":30,"totalTokens":130,"cachedReadTokens":20,"cacheCreationTokens":10,"reasoningTokens":10,"modelUsage":{"grok-4.5-build-free":{"inputTokens":100,"outputTokens":30,"totalTokens":130,"cachedReadTokens":20,"cacheCreationTokens":10,"reasoningTokens":10,"costUsdTicks":123000000,"modelCalls":2}}}},"_meta":{"eventId":"grok-event-1","agentTimestampMs":1784357100000}}}"#
        try [turn, turn].joined(separator: "\n").write(
            to: session.appendingPathComponent("updates.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            grokBuildRootURL: root,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Grok"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Grok"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 130)
        XCTAssertEqual(snapshot.totals.cost, 0.01, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.daily.first?.cost ?? 0, 0.0123, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.daily.first?.tools["Grok"], 130)
        XCTAssertEqual(snapshot.daily.first?.models["grok-build-free"], 130)
        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.inputTokens, 100)
        XCTAssertEqual(work.cachedInputTokens, 20)
        XCTAssertEqual(work.outputTokens, 30)
        XCTAssertEqual(work.modelRequestCount, 2)
    }

    func testQwenCodeCollectorReadsPerRequestUsageAndDeduplicatesIDs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepQwen-\(UUID().uuidString)", isDirectory: true)
        let usageDirectory = root.appendingPathComponent("usage", isDirectory: true)
        try FileManager.default.createDirectory(at: usageDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let request = #"{"schemaVersion":1,"id":"qwen-request-1","timestamp":"2026-05-25T10:00:00.000Z","localDate":"2026-05-25","localMonth":"2026-05","sessionId":"qwen-session","model":"qwen3-coder-plus","authType":"qwen-oauth","source":"memory-agent","inputTokens":10,"outputTokens":20,"cachedTokens":3,"thoughtsTokens":5,"totalTokens":35,"apiDurationMs":100}"#
        try [request, request].joined(separator: "\n").write(
            to: usageDirectory.appendingPathComponent("token-usage-2026-05.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            qwenCodeRootURL: root,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Qwen Code"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Qwen Code"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 35)
        XCTAssertEqual(snapshot.daily.first?.tools["Qwen Code"], 35)
        XCTAssertEqual(snapshot.daily.first?.models["qwen3-coder-plus"], 35)
        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.inputTokens, 10)
        XCTAssertEqual(work.cachedInputTokens, 3)
        XCTAssertEqual(work.outputTokens, 25)
        XCTAssertEqual(work.modelRequestCount, 1)
        XCTAssertEqual(work.sources.first?.source, "Qwen Code")
    }

    func testClineCollectorReadsCurrentAndLegacyExactUsageWithoutDoubleCountingMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepCline-\(UUID().uuidString)", isDirectory: true)
        let currentSession = root.appendingPathComponent("sessions/session-new", isDirectory: true)
        let legacyTask = root.appendingPathComponent("tasks/legacy-task", isDirectory: true)
        let migratedLegacyTask = root.appendingPathComponent("tasks/session-new", isDirectory: true)
        try FileManager.default.createDirectory(at: currentSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyTask, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: migratedLegacyTask, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let current = #"{"version":1,"sessionId":"session-new","messages":[{"id":"assistant-streaming","role":"assistant","ts":1717200000000,"modelInfo":{"id":"claude-sonnet-4"}},{"id":"assistant-final","role":"assistant","ts":1717200001000,"modelInfo":{"id":"claude-sonnet-4"},"metrics":{"inputTokens":21,"outputTokens":8,"cacheReadTokens":3,"cacheWriteTokens":1,"cost":0.13}}]}"#
        try current.write(
            to: currentSession.appendingPathComponent("session-new.messages.json"),
            atomically: true,
            encoding: .utf8
        )

        let legacy = #"[{"ts":1717203600000,"type":"say","say":"api_req_started","text":"{\"model\":\"gpt-5.4\",\"tokensIn\":10}"},{"ts":1717203601000,"type":"say","say":"api_req_finished","text":"{\"tokensOut\":5,\"cacheReads\":3,\"cacheWrites\":2,\"cost\":0.02}"},{"ts":1717207200000,"type":"say","say":"deleted_api_reqs","text":"{\"modelId\":\"gpt-5.4-mini\",\"tokensIn\":4,\"tokensOut\":1,\"cacheReads\":0,\"cacheWrites\":0,\"cost\":0.01}"}]"#
        try legacy.write(
            to: legacyTask.appendingPathComponent("ui_messages.json"),
            atomically: true,
            encoding: .utf8
        )

        let migratedLegacy = #"[{"ts":1717210800000,"type":"say","say":"deleted_api_reqs","text":"{\"model\":\"must-not-count\",\"tokensIn\":999,\"tokensOut\":999}"}]"#
        try migratedLegacy.write(
            to: migratedLegacyTask.appendingPathComponent("ui_messages.json"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            clineRootURLs: [root],
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Cline"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Cline"]?.files, 3)
        XCTAssertEqual(snapshot.sources["Cline"]?.records, 3)
        XCTAssertEqual(snapshot.totals.tokens, 54)
        XCTAssertEqual(snapshot.totals.cost, 0.16, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.daily.first?.tools["Cline"], 54)
        XCTAssertEqual(snapshot.daily.first?.models["claude-sonnet-4"], 29)
        XCTAssertEqual(snapshot.daily.first?.models["gpt-5.4"], 20)
        XCTAssertEqual(snapshot.daily.first?.models["gpt-5.4-mini"], 5)
        XCTAssertNil(snapshot.daily.first?.models["must-not-count"])

        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.inputTokens, 40)
        XCTAssertEqual(work.cachedInputTokens, 6)
        XCTAssertEqual(work.outputTokens, 14)
        XCTAssertEqual(work.modelRequestCount, 3)
        XCTAssertEqual(work.sources.first?.source, "Cline")
    }

    func testCopilotCLICollectorReadsPerRequestSessionStoreUsage() throws {
        let database = try fixtureDatabase(prefix: "TokenStepCopilotCLI")
        try runSQLite(database: database, sql: """
        create table schema_version (version integer not null);
        insert into schema_version values (6);
        create table assistant_usage_events (
            id integer primary key autoincrement,
            session_id text not null,
            model text not null,
            input_tokens integer,
            output_tokens integer,
            cache_read_tokens integer,
            cache_write_tokens integer,
            reasoning_tokens integer,
            token_details_json text,
            created_at text
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

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            copilotDatabaseURL: database,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Copilot CLI"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Copilot CLI"]?.records, 2)
        XCTAssertEqual(snapshot.totals.tokens, 192)
        XCTAssertEqual(snapshot.daily.first?.tools["Copilot CLI"], 192)
        XCTAssertEqual(snapshot.daily.first?.models["gpt-5.6-luna"], 132)
        XCTAssertEqual(snapshot.daily.first?.models["claude-sonnet-4.6"], 60)

        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.inputTokens, 175)
        XCTAssertEqual(work.cachedInputTokens, 40)
        XCTAssertEqual(work.outputTokens, 17)
        XCTAssertEqual(work.modelRequestCount, 2)
        XCTAssertEqual(work.sources.first?.source, "Copilot CLI")
    }

    func testCopilotSessionStoreOnlySuppressesOverlappingCLIOTelHistory() throws {
        let root = try temporaryDirectory(prefix: "TokenStepCopilotOverlap")
        let database = root.appendingPathComponent("session-store.sqlite")
        try runSQLite(database: database, sql: """
        create table assistant_usage_events (
            id integer primary key autoincrement,
            session_id text not null,
            model text not null,
            input_tokens integer,
            output_tokens integer,
            created_at text
        );
        insert into assistant_usage_events (
            session_id, model, input_tokens, output_tokens, created_at
        ) values
            ('copilot-session', 'gpt-5.6-luna', 100, 20, '2026-07-10T10:00:00Z'),
            ('copilot-session', 'gpt-5.6-luna', 50, 10, '2026-07-10T10:01:00Z');
        """)
        let otel = root.appendingPathComponent("copilot-otel.jsonl")
        let overlapping = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-overlap","spanId":"span-overlap","startTimeUnixNano":"1783677600000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"copilot-session","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":20}}"#
        let older = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-old","spanId":"span-old","startTimeUnixNano":"1783591200000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"copilot-session","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":30,"gen_ai.usage.output_tokens":5}}"#
        let otherSession = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-other","spanId":"span-other","startTimeUnixNano":"1783677600000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.conversation.id":"other-session","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":40,"gen_ai.usage.output_tokens":6}}"#
        let unmatchedSameDay = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-unmatched-current","spanId":"span-unmatched-current","startTimeUnixNano":"1783677660000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":200,"gen_ai.usage.output_tokens":20}}"#
        let unmatchedOlder = #"{"resource":{"attributes":{"service.name":"github-copilot"}},"name":"chat","traceId":"trace-unmatched-old","spanId":"span-unmatched-old","startTimeUnixNano":"1783591260000000000","attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"gpt-5.6-luna","gen_ai.usage.input_tokens":9,"gen_ai.usage.output_tokens":2}}"#
        try [overlapping, older, otherSession, unmatchedSameDay, unmatchedOlder].joined(separator: "\n")
            .write(to: otel, atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            copilotDatabaseURL: database,
            copilotOTelURLs: [otel],
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Copilot OTel"]?.records, 3)
        XCTAssertEqual(snapshot.sources["Copilot OTel"]?.skippedRecords, 2)
        XCTAssertEqual(snapshot.totals.tokens, 272)
        XCTAssertEqual(snapshot.daily.map(\.totalTokens).reduce(0, +), 272)
    }

    func testDirtyModelNameIsSanitizedBeforeTeamSyncBucketBuild() throws {
        let root = try temporaryDirectory(prefix: "TokenStepDirtyModel")
        let project = root.appendingPathComponent("projects/example", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let dirtyModel = String(repeating: "e\u{301}", count: 140) + "\u{1F}\ninvalid"
        let collisionPrefix = String(repeating: "x", count: 127)
        let objects: [[String: Any]] = [
            [
                "type": "assistant",
                "timestamp": "2026-07-10T10:00:00Z",
                "sessionId": "dirty-session",
                "message": [
                    "id": "dirty-response",
                    "role": "assistant",
                    "model": dirtyModel,
                    "usage": ["input_tokens": 10, "output_tokens": 2]
                ]
            ],
            [
                "type": "assistant",
                "timestamp": "2026-07-10T10:01:00Z",
                "sessionId": "collision-session",
                "message": [
                    "id": "collision-response-a",
                    "role": "assistant",
                    "model": collisionPrefix,
                    "usage": ["input_tokens": 10, "output_tokens": 2]
                ]
            ],
            [
                "type": "assistant",
                "timestamp": "2026-07-10T10:02:00Z",
                "sessionId": "collision-session",
                "message": [
                    "id": "collision-response-b",
                    "role": "assistant",
                    "model": collisionPrefix + " suffix",
                    "usage": ["input_tokens": 11, "output_tokens": 4]
                ]
            ]
        ]
        let lines = try objects.map { object in
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        try lines.joined(separator: "\n").write(
            to: project.appendingPathComponent("dirty.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            codeBuddyRootURLs: [root],
            includeExperimentalAgentSources: true
        )
        let models = try XCTUnwrap(snapshot.daily.first?.models)
        let model = try XCTUnwrap(models.keys.first(where: { $0.unicodeScalars.count == 128 }))
        XCTAssertEqual(model.unicodeScalars.count, 128)
        XCTAssertFalse(model.contains("\u{1F}"))
        XCTAssertFalse(model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        let buckets = try TeamSyncProtocol.dailyBuckets(snapshot: snapshot)
        XCTAssertEqual(buckets.count, 2)
        let collisionBucket = try XCTUnwrap(buckets.first(where: { $0.model == collisionPrefix }))
        XCTAssertEqual(
            collisionBucket.inputTokens
                + collisionBucket.outputTokens
                + collisionBucket.cacheReadTokens
                + collisionBucket.cacheWriteTokens,
            27
        )
    }

    func testPiCollectorReadsOfficialAssistantUsageAndDeduplicatesSessionCopies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepPi-\(UUID().uuidString)", isDirectory: true)
        let projectA = root.appendingPathComponent("project-a", isDirectory: true)
        let projectB = root.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let header = #"{"type":"session","version":3,"id":"pi-session","timestamp":"2026-07-10T10:00:00Z","cwd":"/tmp/project"}"#
        let assistant = #"{"type":"message","id":"pi-message-1","parentId":"user-1","timestamp":"2026-07-10T10:01:00Z","message":{"role":"assistant","provider":"minimax","model":"minimax-m3","timestamp":1783677660000,"usage":{"input":10,"output":5,"cacheRead":20,"cacheWrite":3,"totalTokens":38,"cost":{"input":0.001,"output":0.01,"cacheRead":0.003,"cacheWrite":0.006,"total":0.02}},"content":[{"type":"text","text":"must not be collected"},{"type":"toolCall","name":"read"}]}}"#
        let body = [header, assistant].joined(separator: "\n") + "\n"
        try body.write(
            to: projectA.appendingPathComponent("pi-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try body.write(
            to: projectB.appendingPathComponent("copied-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            piSessionsRootURL: root,
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["Pi"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Pi"]?.files, 2)
        XCTAssertEqual(snapshot.sources["Pi"]?.records, 1)
        XCTAssertEqual(snapshot.totals.tokens, 38)
        XCTAssertEqual(snapshot.totals.cost, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.daily.first?.tools["Pi"], 38)
        XCTAssertEqual(snapshot.daily.first?.models["minimax-m3"], 38)
        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.inputTokens, 33)
        XCTAssertEqual(work.cachedInputTokens, 20)
        XCTAssertEqual(work.outputTokens, 5)
        XCTAssertEqual(work.toolCallCount, 1)
    }

    func testOpenClawCollectorMergesCurrentSQLiteAndArchivedJSONLWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepOpenClaw-\(UUID().uuidString)", isDirectory: true)
        let agent = root.appendingPathComponent("agents/main/agent", isDirectory: true)
        let sessions = root.appendingPathComponent("agents/main/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let database = agent.appendingPathComponent("openclaw-agent.sqlite")
        let currentEvent = #"{"type":"message","id":"openclaw-current","timestamp":"2026-07-10T10:00:00Z","message":{"role":"assistant","model":"MiniMax-M3","timestamp":1783677600000,"usage":{"input":10,"output":5,"cacheRead":10,"cacheWrite":5,"totalTokens":30,"cost":{"total":0.04}},"content":[{"type":"toolCall","name":"exec"}]}}"#
        let escapedCurrentEvent = currentEvent.replacingOccurrences(of: "'", with: "''")
        try runSQLite(database: database, sql: """
        create table transcript_events (
            session_id text not null,
            seq integer not null,
            event_json text not null,
            created_at integer not null,
            primary key (session_id, seq)
        );
        insert into transcript_events values (
            'openclaw-session', 1, '\(escapedCurrentEvent)', 1783677600000
        );
        """)

        let header = #"{"type":"session","id":"openclaw-session","timestamp":"2026-07-10T09:59:00Z"}"#
        try [header, currentEvent].joined(separator: "\n").appending("\n").write(
            to: sessions.appendingPathComponent("openclaw-session.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let archivedEvent = #"{"type":"message","id":"openclaw-archived","timestamp":"2026-07-10T10:02:00Z","message":{"role":"assistant","model":"qwen3-coder","timestamp":1783677720000,"usage":{"input":3,"output":2,"cacheRead":4,"cacheWrite":1,"totalTokens":10,"cost":{"total":0.01}}}}"#
        try [header, archivedEvent].joined(separator: "\n").appending("\n").write(
            to: sessions.appendingPathComponent("openclaw-session.jsonl.deleted.1783677800000Z"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = UsageCollector.collectUsageSnapshotForTests(
            openClawRootURLs: [root],
            includeExperimentalAgentSources: true
        )

        XCTAssertEqual(snapshot.sources["OpenClaw"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["OpenClaw"]?.files, 3)
        XCTAssertEqual(snapshot.sources["OpenClaw"]?.records, 2)
        XCTAssertEqual(snapshot.totals.tokens, 40)
        XCTAssertEqual(snapshot.totals.cost, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.daily.first?.tools["OpenClaw"], 40)
        XCTAssertEqual(snapshot.daily.first?.models["MiniMax-M3"], 30)
        XCTAssertEqual(snapshot.daily.first?.models["qwen3-coder"], 10)
        let work = try XCTUnwrap(snapshot.agentWork.first)
        XCTAssertEqual(work.inputTokens, 33)
        XCTAssertEqual(work.cachedInputTokens, 14)
        XCTAssertEqual(work.outputTokens, 7)
        XCTAssertEqual(work.toolCallCount, 1)
    }

    private func makeZCodeDatabase(rowsSQL: String) throws -> URL {
        let database = try fixtureDatabase(prefix: "TokenStepZCode")
        try runSQLite(database: database, sql: """
        create table model_usage (
            id text primary key,
            logical_request_id text not null,
            attempt_index integer not null default 0,
            session_id text not null,
            turn_id text,
            trace_id text,
            span_id text,
            assistant_message_id text,
            parent_user_message_id text,
            query_source text not null,
            provider_id text not null,
            model_id text not null,
            variant text,
            agent text,
            mode text,
            task_type text,
            status text not null,
            started_at integer not null,
            first_token_at integer,
            completed_at integer,
            duration_ms integer,
            time_to_first_token_ms integer,
            finish_reason text,
            tool_call_count integer not null default 0,
            input_tokens integer not null default 0,
            output_tokens integer not null default 0,
            reasoning_tokens integer not null default 0,
            cache_creation_input_tokens integer not null default 0,
            cache_read_input_tokens integer not null default 0,
            provider_total_tokens integer,
            computed_total_tokens integer not null default 0,
            retry_count integer not null default 0,
            retryable integer not null default 0,
            cancelled_by_user integer not null default 0,
            context_exceeded integer not null default 0,
            error_type text,
            error_code text,
            error_message text,
            raw_usage_json text,
            provider_metadata_json text
        );
        \(rowsSQL)
        """)
        return database
    }

    private func makeHermesDatabase(rowsSQL: String) throws -> URL {
        let database = try fixtureDatabase(prefix: "TokenStepHermes")
        try runSQLite(database: database, sql: """
        create table sessions (
            id text primary key,
            source text not null,
            user_id text,
            model text,
            model_config text,
            system_prompt text,
            parent_session_id text,
            started_at real not null,
            ended_at real,
            end_reason text,
            message_count integer default 0,
            tool_call_count integer default 0,
            input_tokens integer default 0,
            output_tokens integer default 0,
            cache_read_tokens integer default 0,
            cache_write_tokens integer default 0,
            reasoning_tokens integer default 0,
            billing_provider text,
            billing_base_url text,
            billing_mode text,
            estimated_cost_usd real,
            actual_cost_usd real,
            cost_status text,
            cost_source text,
            pricing_version text,
            title text,
            api_call_count integer default 0
        );
        create table messages (
            id integer primary key autoincrement,
            session_id text not null,
            role text not null,
            content text,
            timestamp real not null
        );
        \(rowsSQL)
        """)
        return database
    }

    private func fixtureDatabase(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("fixture.sqlite")
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makePassthroughZstdDecoder(in root: URL) throws -> URL {
        let executable = root.appendingPathComponent("fixture-zstd")
        try "#!/bin/sh\ncat \"$3\"\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func runSQLite(database: URL, sql: String) throws {
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
            let message = String(data: data, encoding: .utf8) ?? "sqlite fixture failed"
            throw NSError(
                domain: "UsageCollectorExperimentalAgentTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
