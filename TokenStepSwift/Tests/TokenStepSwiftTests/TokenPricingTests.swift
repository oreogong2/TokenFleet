import XCTest
@testable import TokenStepSwift

final class TokenPricingTests: XCTestCase {
    func testGPT54SeparatesFreshCachedAndOutputTokens() throws {
        let estimate = try XCTUnwrap(
            TokenPricingCatalog.estimate(
                tool: "Codex",
                model: "gpt-5.4",
                usage: usage(input: 600_000, output: 200_000, cacheRead: 400_000),
                date: "2026-08-13"
            )
        )

        XCTAssertEqual(estimate.costUSD, 4.6, accuracy: 0.000_001)
        XCTAssertEqual(estimate.pricingVersion, "public-usd-2026-08-14")
        XCTAssertEqual(estimate.provider, "OpenAI")
        XCTAssertEqual(estimate.pricedTokens, 1_200_000)
        XCTAssertEqual(estimate.unpricedTokens, 0)
    }

    func testOpenAICatalogMatchesVerifiedPublicRates() throws {
        struct Row {
            var model: String
            var priceModel: String
            var input: Double
            var output: Double
            var cacheRead: Double
            var cacheWrite: Double
        }
        let rows = [
            Row(model: "gpt-5.6", priceModel: "gpt-5.6-sol", input: 5, output: 30, cacheRead: 0.5, cacheWrite: 6.25),
            Row(model: "gpt-5.6-sol", priceModel: "gpt-5.6-sol", input: 5, output: 30, cacheRead: 0.5, cacheWrite: 6.25),
            Row(model: "gpt-5.6-sol-2026-08-14", priceModel: "gpt-5.6-sol", input: 5, output: 30, cacheRead: 0.5, cacheWrite: 6.25),
            Row(model: "gpt-5.6-terra", priceModel: "gpt-5.6-terra", input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2.5),
            Row(model: "gpt-5.6-luna", priceModel: "gpt-5.6-luna", input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25),
            Row(model: "gpt-5.5", priceModel: "gpt-5.5", input: 5, output: 30, cacheRead: 0.5, cacheWrite: 5),
            Row(model: "gpt-5.4-mini", priceModel: "gpt-5.4-mini", input: 0.75, output: 4.5, cacheRead: 0.075, cacheWrite: 0.75),
            Row(model: "gpt-5.4-nano", priceModel: "gpt-5.4-nano", input: 0.2, output: 1.25, cacheRead: 0.02, cacheWrite: 0.2),
            Row(model: "gpt-5.4", priceModel: "gpt-5.4", input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 2.5),
            Row(model: "gpt-5.3-chat-latest", priceModel: "gpt-5.3-chat", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75),
            Row(model: "gpt-5.2", priceModel: "gpt-5.2", input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75),
            Row(model: "gpt-5.1-chat-latest", priceModel: "gpt-5.1", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25),
            Row(model: "gpt-5-mini", priceModel: "gpt-5-mini", input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0.25),
            Row(model: "gpt-5-nano", priceModel: "gpt-5-nano", input: 0.05, output: 0.4, cacheRead: 0.005, cacheWrite: 0.05),
            Row(model: "gpt-5", priceModel: "gpt-5", input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25)
        ]

        for row in rows {
            let estimate = try XCTUnwrap(
                TokenPricingCatalog.estimate(
                    tool: "Codex",
                    model: row.model,
                    usage: usage(
                        input: 1_000_000,
                        output: 1_000_000,
                        cacheRead: 1_000_000,
                        cacheWrite: 1_000_000
                    ),
                    date: TokenPricingCatalog.verifiedDate
                ),
                row.model
            )
            XCTAssertEqual(
                estimate.costUSD,
                row.input + row.output + row.cacheRead + row.cacheWrite,
                accuracy: 0.000_001,
                row.model
            )
            XCTAssertEqual(estimate.priceModel, row.priceModel, row.model)
            XCTAssertEqual(estimate.pricingVersion, TokenPricingCatalog.version, row.model)
        }
    }

    func testCatalogVersionOnlyReestimatesOlderOrUnversionedSnapshots() {
        XCTAssertTrue(TokenPricingCatalog.shouldReestimate(storedVersion: nil))
        XCTAssertTrue(TokenPricingCatalog.shouldReestimate(storedVersion: "public-usd-2026-08-13"))
        XCTAssertFalse(TokenPricingCatalog.shouldReestimate(storedVersion: TokenPricingCatalog.version))
        XCTAssertFalse(TokenPricingCatalog.shouldReestimate(storedVersion: "public-usd-2026-08-15"))
        XCTAssertFalse(TokenPricingCatalog.shouldReestimate(storedVersion: "provider-catalog-v2"))

        XCTAssertFalse(TokenPricingCatalog.shouldPreserveSnapshot(storedVersion: nil))
        XCTAssertFalse(TokenPricingCatalog.shouldPreserveSnapshot(storedVersion: "public-usd-2026-08-13"))
        XCTAssertFalse(TokenPricingCatalog.shouldPreserveSnapshot(storedVersion: TokenPricingCatalog.version))
        XCTAssertTrue(TokenPricingCatalog.shouldPreserveSnapshot(storedVersion: "public-usd-2026-08-15"))
        XCTAssertTrue(TokenPricingCatalog.shouldPreserveSnapshot(storedVersion: "provider-catalog-v2"))
    }

    func testNearMatchIsUnpricedInsteadOfGuessingAnAlias() {
        for model in [
            "gpt-5.6-sol-preview",
            "gpt-5.6-2026-preview",
            "gpt-5.6-sol-2026-08-14-preview"
        ] {
            XCTAssertNil(
                TokenPricingCatalog.estimate(
                    tool: "Codex",
                    model: model,
                    usage: usage(input: 1_000_000, output: 1_000_000),
                    date: TokenPricingCatalog.verifiedDate
                ),
                model
            )
        }
    }

    func testCurrentClaudeOpusIncludesCacheReadRateWhenNoWriteTTLIsNeeded() throws {
        let estimate = try XCTUnwrap(
            TokenPricingCatalog.estimate(
                tool: "Claude Code",
                model: "claude-opus-4-8",
                usage: usage(
                    input: 1_000_000,
                    output: 1_000_000,
                    cacheRead: 1_000_000
                ),
                date: "2026-08-13"
            )
        )

        XCTAssertEqual(estimate.costUSD, 30.5, accuracy: 0.000_001)
        XCTAssertEqual(estimate.provider, "Anthropic")
    }

    func testClaudeCacheWriteWithoutTTLLeavesOnlyThatComponentUnpriced() throws {
        let estimate = try XCTUnwrap(
            TokenPricingCatalog.estimate(
                tool: "Claude Code",
                model: "claude-opus-4-8",
                usage: usage(input: 1_000_000, output: 0, cacheWrite: 1_000_000),
                date: "2026-08-13"
            )
        )
        XCTAssertEqual(estimate.costUSD, 5, accuracy: 0.000_001)
        XCTAssertEqual(estimate.pricedTokens, 1_000_000)
        XCTAssertEqual(estimate.unpricedTokens, 1_000_000)
    }

    func testSonnet5PriceChangesAtDocumentedEffectiveDate() throws {
        let tokenUsage = usage(input: 1_000_000, output: 1_000_000)
        let promotional = try XCTUnwrap(
            TokenPricingCatalog.estimate(
                tool: "Claude Code",
                model: "claude-sonnet-5",
                usage: tokenUsage,
                date: "2026-08-31"
            )
        )
        let standard = try XCTUnwrap(
            TokenPricingCatalog.estimate(
                tool: "Claude Code",
                model: "claude-sonnet-5",
                usage: tokenUsage,
                date: "2026-09-01"
            )
        )

        XCTAssertEqual(promotional.costUSD, 12, accuracy: 0.000_001)
        XCTAssertEqual(standard.costUSD, 18, accuracy: 0.000_001)
    }

    func testUnknownModelIsUnpricedInsteadOfUsingGenericFallback() {
        XCTAssertNil(
            TokenPricingCatalog.estimate(
                tool: "Claude Code",
                model: "claude-future-unknown",
                usage: usage(input: 1_000_000, output: 1_000_000),
                date: "2026-08-13"
            )
        )
        XCTAssertNil(
            TokenPricingCatalog.estimate(
                tool: "Kimi CLI",
                model: "kimi-unknown",
                usage: usage(input: 1_000_000, output: 1_000_000),
                date: "2026-08-13"
            )
        )
    }

    func testIncompleteBreakdownIsUnpricedEvenForKnownModel() {
        XCTAssertNil(
            TokenPricingCatalog.estimate(
                tool: "Codex",
                model: "gpt-5.4",
                usage: TokenPricingUsage(
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    totalTokens: 1_000_000,
                    breakdownComplete: false
                ),
                date: "2026-08-13"
            )
        )
    }

    func testRouterOrUnknownModelAliasesAreNotGuessed() {
        XCTAssertNil(
            TokenPricingCatalog.estimate(
                tool: "Codex via CC Switch",
                model: "gpt-5.4-custom-router",
                usage: usage(input: 1_000_000, output: 0),
                date: "2026-08-13"
            )
        )
    }

    private func usage(
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> TokenPricingUsage {
        TokenPricingUsage(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            totalTokens: input + output + cacheRead + cacheWrite,
            breakdownComplete: true
        )
    }
}
