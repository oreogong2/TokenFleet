import Foundation
import XCTest
@testable import TokenStepSwift

final class TokenPricingTests: XCTestCase {
    func testPythonCatalogHashAndEffectiveDatesMatch() throws {
        let context = try TokenPriceCatalogFixture.context
        let usage = usage(input: 600_000, output: 200_000, cacheRead: 400_000)
        let old = try XCTUnwrap(context.catalog.estimate(tool: "Codex", model: "openai/gpt_6_sol-20260102", usage: usage,
            date: "2026-08-31", pricingVersion: context.pricingVersion))
        let new = try XCTUnwrap(context.catalog.estimate(tool: "Cursor", model: "gpt-6-sol", usage: usage,
            date: "2026-09-01", pricingVersion: context.pricingVersion))
        XCTAssertEqual(old.costUSD, 1.30, accuracy: 0.000001)
        XCTAssertEqual(new.costUSD, 1.55, accuracy: 0.000001)
        XCTAssertEqual(new.pricedTokens, 1_200_000)
        XCTAssertEqual(new.unpricedTokens, 0)
        XCTAssertTrue(new.pricingVersion.hasPrefix("server-usd-v1:"))
        XCTAssertNil(context.catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: usage,
            date: "2025-12-31", pricingVersion: context.pricingVersion))
    }

    func testPythonUnicodeHistoryCatalogAndOneHourEstimates() throws {
        // Synthetic protocol fixture, with its UTF-8 hash generated in Python.
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/server-price-history-v1.json")
        let catalog = try ServerTokenPriceCatalog.decode(Data(contentsOf: file))
        for model in ["gpt-5.6-sol", "gpt-5.6"] {
            for (day, expected) in [("2026-08-14", 5.0), ("2026-08-20", 5.0),
                                    ("2026-08-21", 4.0), ("2026-09-26", 4.0)] {
                let cost = try XCTUnwrap(catalog.estimate(tool: "Codex", model: model,
                    usage: usage(input: 1_000_000), date: day, pricingVersion: "fixture"))
                XCTAssertEqual(cost.costUSD, expected, accuracy: 0.000001)
            }
        }
        for (day, expected) in [("2026-08-31", 4.0), ("2026-09-01", 6.0),
                                ("2026-09-25", 6.0), ("2026-09-26", 4.0)] {
            let cost = try XCTUnwrap(catalog.estimate(tool: "Claude Code", model: "claude-sonnet-5",
                usage: usage(input: 0, cacheWrite: 1_000_000), date: day, pricingVersion: "fixture"))
            XCTAssertEqual(cost.costUSD, expected, accuracy: 0.000001)
            XCTAssertEqual(cost.pricedTokens, 1_000_000)
        }
        XCTAssertTrue(catalog.prices.filter { $0.model.hasPrefix("claude-") }
            .allSatisfy { $0.pricingNote == "缓存写入按 1 小时档估算" })
    }

    func testMicrounitHalfUpRoundingMatchesServer() throws {
        let context = try TokenPriceCatalogFixture.context
        for (input, expected) in [(1, 0.000002), (3, 0.000005)] {
            let result = try XCTUnwrap(context.catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: usage(input: input),
                date: "2026-09-26", pricingVersion: context.pricingVersion))
            XCTAssertEqual(result.costUSD, expected, accuracy: 0.00000001)
        }
    }

    func testConservativeAliasesAndMalformedDatesStayUnpriced() throws {
        let context = try TokenPriceCatalogFixture.context
        for model in ["custom-local/gpt-6-sol", "router/gpt-6-sol", "gpt-6-sol-preview", "gpt-6-sol-20260230", "unknown"] {
            XCTAssertNil(context.catalog.estimate(tool: "Codex", model: model, usage: usage(input: 100),
                date: "2026-09-26", pricingVersion: context.pricingVersion), model)
        }
        XCTAssertEqual(ServerTokenPriceCatalog.normalizeModel("Anthropic/claude_fable_5-1-20260901"), "claude-fable-5.1")
        XCTAssertEqual(ServerTokenPriceCatalog.normalizeModel("gpt-5-6-sol"), "gpt-5.6-sol")
        XCTAssertEqual(ServerTokenPriceCatalog.normalizeModel("gpt-6-sol-20260230"), "gpt-6-sol-20260230")
        XCTAssertNil(context.catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: usage(input: 100),
            date: "2026-02-30", pricingVersion: context.pricingVersion))
    }

    func testIncompleteBreakdownAndOverflowHaveNoGenericFallback() throws {
        let context = try TokenPriceCatalogFixture.context
        var incomplete = usage(input: 100)
        incomplete.breakdownComplete = false
        XCTAssertNil(context.catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: incomplete,
            date: "2026-09-26", pricingVersion: context.pricingVersion))
        var mismatch = usage(input: 100)
        mismatch.totalTokens = 101
        XCTAssertNil(context.catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: mismatch,
            date: "2026-09-26", pricingVersion: context.pricingVersion))
        XCTAssertFalse(usage(input: Int.max, output: 1, total: Int.max).componentsMatchTotal)
        XCTAssertNil(context.catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: usage(input: Int.max),
            date: "2026-09-26", pricingVersion: context.pricingVersion))
    }

    func testConflictingAliasRatesDoNotChooseAnInsertionOrder() throws {
        var body = try JSONSerialization.jsonObject(with: TokenPriceCatalogFixture.payload) as! [String: Any]
        var rows = body["prices"] as! [[String: String]]
        var duplicate = rows[1]
        duplicate["id"] = "00000000-0000-4000-8000-000000000099"
        duplicate["input_per_million"] = "9"
        rows.append(duplicate)
        body["prices"] = rows
        let catalog = try ServerTokenPriceCatalog.decode(TokenPriceCatalogFixture.replacing(["prices": rows]))
        XCTAssertNil(catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: usage(input: 100),
            date: "2026-09-26", pricingVersion: "synthetic"))
    }

    func testCatalogRejectsTamperingFutureSchemaAndInvalidRates() throws {
        var body = try JSONSerialization.jsonObject(with: TokenPriceCatalogFixture.payload) as! [String: Any]
        body["revision"] = 3
        XCTAssertThrowsError(try ServerTokenPriceCatalog.decode(JSONSerialization.data(withJSONObject: body)))
        for changes: [String: Any] in [["schema_version": 2], ["normalization_version": 2], ["revision": -1], ["basis": "invoice"]] {
            XCTAssertThrowsError(try ServerTokenPriceCatalog.decode(TokenPriceCatalogFixture.replacing(changes)))
        }
        var rows = body["prices"] as! [[String: String]]
        rows[0]["input_per_million"] = "NaN"
        XCTAssertThrowsError(try ServerTokenPriceCatalog.decode(TokenPriceCatalogFixture.replacing(["prices": rows])))
    }

    func testCacheKeepsValidOfflineCatalogAndRejectsRollbacksAndOtherOrigins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog.json")
        let origin = URL(string: "https://community.example.com")!
        XCTAssertTrue(try TokenPriceCatalogCache.save(TokenPriceCatalogFixture.payload, origin: origin, at: file))
        XCTAssertFalse(try TokenPriceCatalogCache.save(TokenPriceCatalogFixture.payload, origin: origin, at: file))
        XCTAssertNotNil(TokenPriceCatalogCache.load(at: file, origin: origin))
        XCTAssertNil(TokenPriceCatalogCache.load(at: file, origin: URL(string: "https://other.example.com")!))
        let before = try Data(contentsOf: file)
        for payload in [try TokenPriceCatalogFixture.replacing(["revision": 1]),
                        try TokenPriceCatalogFixture.replacing(["prices": []]), Data("invalid".utf8)] {
            XCTAssertThrowsError(try TokenPriceCatalogCache.save(payload, origin: origin, at: file))
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
        XCTAssertTrue(try TokenPriceCatalogCache.save(TokenPriceCatalogFixture.replacing(["revision": 3, "prices": []]), origin: origin, at: file))
        XCTAssertEqual(TokenPriceCatalogCache.load(at: file, origin: origin)?.catalog.prices.count, 0)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testUnknownCacheRatesOnlyBlockNonzeroComponents() throws {
        let body = try JSONSerialization.jsonObject(with: TokenPriceCatalogFixture.payload) as! [String: Any]
        for key in ["cache_read_per_million", "cache_write_per_million"] {
            var rows = body["prices"] as! [[String: Any]]
            rows[1][key] = NSNull()
            let catalog = try ServerTokenPriceCatalog.decode(TokenPriceCatalogFixture.replacing(["prices": rows]))
            XCTAssertNotNil(catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: usage(input: 100),
                date: "2026-09-26", pricingVersion: "synthetic"))
            let used = key == "cache_read_per_million" ? usage(input: 100, cacheRead: 1) : usage(input: 100, cacheWrite: 1)
            XCTAssertNil(catalog.estimate(tool: "Codex", model: "gpt-6-sol", usage: used,
                date: "2026-09-26", pricingVersion: "synthetic"))
        }
    }

    func testMissingCatalogDoesNotGuessPricesAndFutureSnapshotsArePreserved() {
        XCTAssertTrue(TokenPricingCatalog.shouldReestimate(storedVersion: nil))
        XCTAssertTrue(TokenPricingCatalog.shouldReestimate(storedVersion: "public-usd-2026-08-14"))
        XCTAssertFalse(TokenPricingCatalog.shouldReestimate(storedVersion: TokenPricingCatalog.version))
        XCTAssertTrue(TokenPricingCatalog.shouldPreserveSnapshot(storedVersion: "server-usd-v2:future"))
        XCTAssertFalse(TokenPricingCatalog.shouldReestimate(storedVersion: "provider-catalog-v2"))
    }

    private func usage(input: Int, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, total: Int? = nil) -> TokenPricingUsage {
        TokenPricingUsage(inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            totalTokens: total ?? (input + output + cacheRead + cacheWrite), breakdownComplete: true)
    }
}
