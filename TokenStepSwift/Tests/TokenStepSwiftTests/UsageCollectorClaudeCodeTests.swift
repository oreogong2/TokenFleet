import Foundation
import XCTest
@testable import TokenStepSwift

final class UsageCollectorClaudeCodeTests: XCTestCase {
    func testClaudeCodeDeduplicatesAssistantContentBlocksByMessageID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepClaudeTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let log = project.appendingPathComponent("session.jsonl")
        try fixtureLines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectClaudeCodeUsageSnapshot(rootURL: root)

        XCTAssertEqual(snapshot.sources["Claude Code"]?.status, "ok")
        XCTAssertEqual(snapshot.sources["Claude Code"]?.records, 3)
        XCTAssertEqual(snapshot.totals.tokens, 324)
        XCTAssertEqual(snapshot.daily.count, 1)
        XCTAssertEqual(snapshot.daily.first?.date, "2026-06-21")
        XCTAssertEqual(snapshot.daily.first?.tools["Claude Code"], 324)
        XCTAssertEqual(snapshot.daily.first?.models["claude-opus-4-20250514"], 322)
        XCTAssertEqual(snapshot.daily.first?.models["unknown"], 2)
        let atomic = try XCTUnwrap(snapshot.daily.first?.atomicUsage)
        XCTAssertEqual(atomic.reduce(0) { $0 + $1.totalTokens }, 324)
        let opus = try XCTUnwrap(atomic.first { $0.model == "claude-opus-4-20250514" })
        XCTAssertEqual(opus.inputTokens, 17)
        XCTAssertEqual(opus.outputTokens, 5)
        XCTAssertEqual(opus.cacheReadTokens, 300)
        XCTAssertEqual(opus.cacheWriteTokens, 0)
        XCTAssertEqual(opus.totalTokens, 322)
    }

    func testClaudeUsesFetchedPricesForTheSameCompleteBucket() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStepClaudeCostTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let log = project.appendingPathComponent("session.jsonl")
        let line = assistantLine(
            uuid: "opus-cost",
            messageID: "msg_opus_cost",
            timestamp: "2026-06-21T08:00:00Z",
            model: "claude-fable-5.1",
            stopReason: "end_turn",
            input: 1_000_000,
            output: 1_000_000,
            cacheCreation: 1_000_000,
            cacheRead: 1_000_000
        )
        try line.write(to: log, atomically: true, encoding: .utf8)

        let snapshot = UsageCollector.collectClaudeCodeUsageSnapshot(rootURL: root, pricing: try TokenPriceCatalogFixture.context)

        XCTAssertEqual(snapshot.totals.tokens, 4_000_000)
        XCTAssertEqual(snapshot.totals.cost, 3.6)
        XCTAssertEqual(snapshot.daily.first?.cost, 3.6)
        XCTAssertEqual(snapshot.totals.pricedTokens, 4_000_000)
        XCTAssertEqual(snapshot.totals.unpricedTokens, 0)
        XCTAssertEqual(snapshot.daily.first?.pricedTokens, 4_000_000)
        XCTAssertEqual(snapshot.daily.first?.unpricedTokens, 0)
    }

    func testRoundingOccursAfterCompleteRecordsAreCombinedIntoTheServerBucket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...2).map { index in
            assistantLine(uuid: "round-\(index)", messageID: "msg_round_\(index)",
                timestamp: "2026-09-26T08:00:0\(index)Z", model: "gpt-6-sol",
                stopReason: "end_turn", input: 1, output: 0, cacheRead: 0)
        }
        try lines.joined(separator: "\n").write(to: project.appendingPathComponent("round.jsonl"), atomically: true, encoding: .utf8)
        let snapshot = UsageCollector.collectClaudeCodeUsageSnapshot(rootURL: root, pricing: try TokenPriceCatalogFixture.context)
        XCTAssertEqual(snapshot.totals.tokens, 2)
        XCTAssertEqual(snapshot.daily.first?.atomicUsage?.count, 1)
        XCTAssertEqual(snapshot.daily.first?.atomicUsage?.first?.inputTokens, 2)
        XCTAssertEqual(snapshot.daily.first?.cost ?? -1, 0.000003, accuracy: 0.00000001)
        XCTAssertEqual(snapshot.totals.pricedTokens, 2)
        XCTAssertEqual(snapshot.totals.unpricedTokens, 0)
    }

    private var fixtureLines: [String] {
        [
            assistantLine(
                uuid: "block-thinking",
                messageID: "msg_same_response",
                timestamp: "2026-06-21T08:00:00Z",
                model: "claude-opus-4-20250514",
                stopReason: nil,
                input: 10,
                output: 3,
                cacheRead: 100
            ),
            assistantLine(
                uuid: "block-text",
                messageID: "msg_same_response",
                timestamp: "2026-06-21T08:00:01Z",
                model: "claude-opus-4-20250514",
                stopReason: "end_turn",
                input: 10,
                output: 3,
                cacheRead: 100
            ),
            assistantLine(
                uuid: "tool-1",
                messageID: "msg_tool_batch",
                timestamp: "2026-06-21T08:01:00Z",
                model: "claude-opus-4-20250514",
                stopReason: nil,
                input: 7,
                output: 2,
                cacheRead: 200
            ),
            assistantLine(
                uuid: "tool-2",
                messageID: "msg_tool_batch",
                timestamp: "2026-06-21T08:01:01Z",
                model: "claude-opus-4-20250514",
                stopReason: nil,
                input: 7,
                output: 2,
                cacheRead: 200
            ),
            assistantLine(
                uuid: "legacy-1",
                messageID: nil,
                timestamp: "2026-06-21T08:02:00Z",
                model: nil,
                stopReason: "end_turn",
                input: 1,
                output: 1,
                cacheRead: 0
            ),
            assistantLine(
                uuid: "legacy-1",
                messageID: nil,
                timestamp: "2026-06-21T08:02:01Z",
                model: nil,
                stopReason: "end_turn",
                input: 1,
                output: 1,
                cacheRead: 0
            )
        ]
    }

    private func assistantLine(
        uuid: String,
        messageID: String?,
        timestamp: String,
        model: String?,
        stopReason: String?,
        input: Int,
        output: Int,
        cacheCreation: Int = 0,
        cacheRead: Int
    ) -> String {
        var message: [String: Any] = [
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cache_creation_input_tokens": cacheCreation,
                "cache_read_input_tokens": cacheRead
            ]
        ]
        if let messageID {
            message["id"] = messageID
        }
        if let model {
            message["model"] = model
        }
        if let stopReason {
            message["stop_reason"] = stopReason
        }

        let object: [String: Any] = [
            "type": "assistant",
            "uuid": uuid,
            "timestamp": timestamp,
            "message": message
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
