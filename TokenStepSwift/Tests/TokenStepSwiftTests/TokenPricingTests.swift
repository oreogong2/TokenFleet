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
        XCTAssertEqual(estimate.pricingVersion, "public-usd-2026-08-13")
        XCTAssertEqual(estimate.provider, "OpenAI")
        XCTAssertEqual(estimate.pricedTokens, 1_200_000)
        XCTAssertEqual(estimate.unpricedTokens, 0)
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
