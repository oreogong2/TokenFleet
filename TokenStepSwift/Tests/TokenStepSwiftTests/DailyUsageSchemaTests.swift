import Foundation
import XCTest
@testable import TokenStepSwift

final class DailyUsageSchemaTests: XCTestCase {
    func testLegacyDailyUsageDecodesWithoutInventingAtomicRelationship() throws {
        let data = Data(#"""
        {
          "date":"2026-08-08",
          "tools":{"Claude Code":70,"Codex":30},
          "models":{"claude-opus":60,"gpt-5":40},
          "total_tokens":100,
          "cost":0.5
        }
        """#.utf8)

        let row = try JSONDecoder().decode(DailyUsage.self, from: data)

        XCTAssertNil(row.atomicUsage)
        XCTAssertNil(row.pricingCoverage)
        XCTAssertNil(row.pricingVersion)
        XCTAssertEqual(row.tools["Claude Code"], 70)
        XCTAssertEqual(row.models["gpt-5"], 40)
    }

    func testLegacyMissingPricingCoverageDoesNotPresentZeroCostAsPriced() {
        XCTAssertEqual(TokenStepFormat.estimatedMoney(0, coverage: nil), "未计价")
        XCTAssertEqual(TokenStepFormat.estimatedMoney(0, coverage: 0), "未计价")
    }

    func testExactAtomicUsageRoundTripsAllTokenComponents() throws {
        let original = DailyUsage(
            date: "2026-08-09",
            tools: ["Claude Code": 1_250],
            models: ["claude-opus": 1_250],
            atomicUsage: [
                DailyAtomicUsage(
                    tool: "Claude Code",
                    model: "claude-opus",
                    inputTokens: 120,
                    outputTokens: 80,
                    cacheReadTokens: 1_000,
                    cacheWriteTokens: 50,
                    totalTokens: 1_250
                )
            ],
            totalTokens: 1_250,
            cost: 0.42,
            pricedTokens: 1_000,
            unpricedTokens: 250,
            pricingVersion: "public-usd-2026-08-13"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DailyUsage.self, from: data)

        XCTAssertEqual(decoded.atomicUsage, original.atomicUsage)
        XCTAssertEqual(decoded.atomicUsage?.first?.breakdownComplete, true)
        XCTAssertEqual(decoded.totalTokens, original.totalTokens)
        XCTAssertEqual(try XCTUnwrap(decoded.pricingCoverage), 0.8, accuracy: 0.000_001)
        XCTAssertEqual(decoded.pricingVersion, "public-usd-2026-08-13")
        XCTAssertNotNil(decoded.atomicUsage)
    }

    func testMissingCompletenessFlagIsDerivedWithoutInventingExactComponents() throws {
        let atomicJSON = Data(#"{"tool":"Codex","model":"unknown","input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_write_tokens":0,"total_tokens":100}"#.utf8)

        let atomic = try JSONDecoder().decode(DailyAtomicUsage.self, from: atomicJSON)

        XCTAssertEqual(atomic.totalTokens, 100)
        XCTAssertFalse(atomic.breakdownComplete)
    }

    func testEmptyAtomicArrayRemainsDistinctFromLegacyNil() throws {
        let original = DailyUsage(
            date: "2026-08-09",
            tools: [:],
            atomicUsage: [],
            totalTokens: 0,
            cost: 0
        )

        let decoded = try JSONDecoder().decode(
            DailyUsage.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertNotNil(decoded.atomicUsage)
        XCTAssertEqual(decoded.atomicUsage, [])
    }

    func testLegacyHourlyAgentSourceDefaultsMissingModelToUnknown() throws {
        let data = Data(#"""
        {
          "source":"Codex",
          "tokens":120,
          "input_tokens":80,
          "cached_input_tokens":20,
          "output_tokens":40,
          "cache_coverage_complete":true
        }
        """#.utf8)

        let row = try JSONDecoder().decode(AgentWorkHourlySource.self, from: data)

        XCTAssertEqual(row.source, "Codex")
        XCTAssertEqual(row.model, "unknown")
        XCTAssertEqual(row.tokens, 120)
    }

    func testLegacySettingsDefaultTeamSyncToOffWithoutServer() throws {
        let settings = try JSONDecoder().decode(TokenStepSettings.self, from: Data("{}".utf8))

        XCTAssertFalse(settings.teamSyncEnabled)
        XCTAssertEqual(settings.teamSyncServerURL, "")
        XCTAssertFalse(settings.menuBarShowsTokenCount)
    }

    func testMenuBarTokenCountPreferenceRoundTrips() throws {
        var settings = TokenStepSettings.defaults
        settings.menuBarShowsTokenCount = true

        let decoded = try JSONDecoder().decode(
            TokenStepSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertTrue(decoded.menuBarShowsTokenCount)
    }

    func testLegacyFloatingIslandSettingsMigrateToNativeMenuBarWithoutLosingCountPreference() {
        var settings = TokenStepSettings.defaults
        settings.tokenIslandEnabled = true
        settings.tokenIslandPlacement = .notchLeft
        settings.menuBarShowsTokenCount = true

        let normalized = DataService.normalize(settings)

        XCTAssertFalse(normalized.tokenIslandEnabled)
        XCTAssertEqual(normalized.tokenIslandPlacement, .menuBar)
        XCTAssertTrue(normalized.menuBarShowsTokenCount)
    }

    func testCollectedSourceCountExcludesDisabledMissingAndUnsupportedCollectors() {
        var snapshot = UsageSnapshot.empty
        snapshot.sources = [
            "Codex": SourceInfo(status: "ok", records: 3),
            "Codex SQLite Fallback": SourceInfo(status: "ok_sqlite", records: 2),
            "Claude Code": SourceInfo(status: "missing", records: 0),
            "CC Switch Proxy": SourceInfo(status: "disabled", records: 0),
            "WorkBuddy": SourceInfo(status: "unsupported_privacy_boundary", records: 0),
            "Empty Successful Source": SourceInfo(status: "ok", records: 0)
        ]

        XCTAssertEqual(snapshot.collectedSourceCount, 2)
    }
}
