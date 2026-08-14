import Foundation

/// Normalized, mutually-exclusive token buckets used by the public-price estimator.
///
/// The estimator intentionally refuses total-only or ambiguous records. A missing
/// estimate is more honest than silently applying a generic per-token fallback.
struct TokenPricingUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var totalTokens: Int
    var breakdownComplete: Bool

    var componentsMatchTotal: Bool {
        let values = [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens]
        guard values.allSatisfy({ $0 >= 0 }) else { return false }
        let (inputAndOutput, overflow1) = inputTokens.addingReportingOverflow(outputTokens)
        let (withCacheRead, overflow2) = inputAndOutput.addingReportingOverflow(cacheReadTokens)
        let (componentTotal, overflow3) = withCacheRead.addingReportingOverflow(cacheWriteTokens)
        return !overflow1 && !overflow2 && !overflow3 && componentTotal == totalTokens
    }
}

struct TokenCostEstimate: Equatable {
    var costUSD: Double
    var pricingVersion: String
    var provider: String
    var priceModel: String
    var pricedTokens: Int
    var unpricedTokens: Int
}

/// Versioned public list-price catalog for records that do not contain a source cost.
///
/// Rates are USD per one million tokens, verified against provider documentation on
/// 2026-08-14. Model matching is deliberately exact (plus dated snapshot suffixes),
/// so aliases, routers, service tiers and unknown future models remain unpriced.
enum TokenPricingCatalog {
    static let version = "public-usd-2026-08-14"
    static let verifiedDate = "2026-08-14"

    private struct Rates {
        var provider: String
        var priceModel: String
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    static func estimate(
        tool: String,
        model: String,
        usage: TokenPricingUsage,
        date: String
    ) -> TokenCostEstimate? {
        guard usage.breakdownComplete, usage.componentsMatchTotal else { return nil }
        guard let rates = rates(tool: tool, model: model, date: date) else { return nil }
        let cost = dollars(usage.inputTokens, rate: rates.input)
            + dollars(usage.outputTokens, rate: rates.output)
            + dollars(usage.cacheReadTokens, rate: rates.cacheRead)
            // Anthropic has different 5-minute and 1-hour cache-write rates.
            // The normalized ledger does not preserve that TTL, so only this
            // component remains unpriced instead of discarding known costs.
            + (rates.provider == "Anthropic"
                ? 0
                : dollars(usage.cacheWriteTokens, rate: rates.cacheWrite))
        let unpricedTokens = rates.provider == "Anthropic" ? usage.cacheWriteTokens : 0
        return TokenCostEstimate(
            costUSD: cost,
            pricingVersion: version,
            provider: rates.provider,
            priceModel: rates.priceModel,
            pricedTokens: usage.totalTokens - unpricedTokens,
            unpricedTokens: unpricedTokens
        )
    }

    /// Returns true only when a stored snapshot is unversioned or uses an older
    /// dated public-price catalog. A snapshot written by a newer app is never
    /// downgraded merely because an older binary was launched.
    static func shouldReestimate(storedVersion: String?) -> Bool {
        guard storedVersion != version else { return false }
        guard let storedVersion, !storedVersion.isEmpty else { return true }
        let prefix = "public-usd-"
        guard storedVersion.hasPrefix(prefix), version.hasPrefix(prefix) else {
            return false
        }
        return storedVersion < version
    }

    /// An older binary must not overwrite estimates written by a newer or
    /// unrecognized catalog. It cannot truthfully price newly collected rows
    /// with rules that it does not know.
    static func shouldPreserveSnapshot(storedVersion: String?) -> Bool {
        guard let storedVersion, !storedVersion.isEmpty, storedVersion != version else {
            return false
        }
        let prefix = "public-usd-"
        guard storedVersion.hasPrefix(prefix), version.hasPrefix(prefix) else {
            return true
        }
        return storedVersion > version
    }

    private static func rates(tool: String, model: String, date: String) -> Rates? {
        let normalizedTool = normalize(tool)
        let normalizedModel = normalize(model)

        if normalizedTool.contains("codex") {
            return openAIRates(model: normalizedModel)
        }
        if normalizedTool.contains("claude") {
            return anthropicRates(model: normalizedModel, date: date)
        }
        return nil
    }

    private static func openAIRates(model: String) -> Rates? {
        let rows: [(aliases: [String], rates: Rates)] = [
            (["gpt-5.6-sol", "gpt-5.6"], openAI("gpt-5.6-sol", 5, 30, 0.5, 6.25)),
            (["gpt-5.6-terra"], openAI("gpt-5.6-terra", 2, 12, 0.2, 2.5)),
            (["gpt-5.6-luna"], openAI("gpt-5.6-luna", 0.2, 1.2, 0.02, 0.25)),
            (["gpt-5.5"], openAI("gpt-5.5", 5, 30, 0.5, 5)),
            (["gpt-5.4-mini"], openAI("gpt-5.4-mini", 0.75, 4.5, 0.075, 0.75)),
            (["gpt-5.4-nano"], openAI("gpt-5.4-nano", 0.2, 1.25, 0.02, 0.2)),
            (["gpt-5.4"], openAI("gpt-5.4", 2.5, 15, 0.25, 2.5)),
            (["gpt-5.3-chat-latest", "gpt-5.3-chat"], openAI("gpt-5.3-chat", 1.75, 14, 0.175, 1.75)),
            (["gpt-5.2"], openAI("gpt-5.2", 1.75, 14, 0.175, 1.75)),
            (["gpt-5.1-chat-latest", "gpt-5.1-chat", "gpt-5.1"], openAI("gpt-5.1", 1.25, 10, 0.125, 1.25)),
            (["gpt-5-mini"], openAI("gpt-5-mini", 0.25, 2, 0.025, 0.25)),
            (["gpt-5-nano"], openAI("gpt-5-nano", 0.05, 0.4, 0.005, 0.05)),
            (["gpt-5"], openAI("gpt-5", 1.25, 10, 0.125, 1.25))
        ]
        return rows.first { row in row.aliases.contains(where: { matches(model, alias: $0) }) }?.rates
    }

    private static func anthropicRates(model: String, date: String) -> Rates? {
        let rows: [(aliases: [String], rates: Rates)] = [
            (["claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8"],
             anthropic("claude-opus-4.5–4.8", 5, 25, 0.5, 6.25)),
            (["claude-opus-4", "claude-opus-4-1"],
             anthropic("claude-opus-4/4.1", 15, 75, 1.5, 18.75)),
            (["claude-sonnet-4", "claude-sonnet-4-5", "claude-sonnet-4-6"],
             anthropic("claude-sonnet-4/4.5/4.6", 3, 15, 0.3, 3.75)),
            (["claude-haiku-4-5"], anthropic("claude-haiku-4.5", 1, 5, 0.1, 1.25))
        ]
        if matches(model, alias: "claude-sonnet-5") {
            if date <= "2026-08-31" {
                return anthropic("claude-sonnet-5-promo", 2, 10, 0.2, 2.5)
            }
            return anthropic("claude-sonnet-5", 3, 15, 0.3, 3.75)
        }
        return rows.first { row in row.aliases.contains(where: { matches(model, alias: $0) }) }?.rates
    }

    private static func openAI(
        _ model: String,
        _ input: Double,
        _ output: Double,
        _ cacheRead: Double,
        _ cacheWrite: Double
    ) -> Rates {
        Rates(
            provider: "OpenAI",
            priceModel: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite
        )
    }

    private static func anthropic(
        _ model: String,
        _ input: Double,
        _ output: Double,
        _ cacheRead: Double,
        _ cacheWrite: Double
    ) -> Rates {
        Rates(
            provider: "Anthropic",
            priceModel: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite
        )
    }

    private static func matches(_ model: String, alias: String) -> Bool {
        guard model != alias else { return true }
        guard model.hasPrefix(alias) else { return false }
        let suffix = String(model.dropFirst(alias.count))
        guard suffix.first == "-" else { return false }
        let date = String(suffix.dropFirst())
        if date.count == 8 {
            return date.hasPrefix("20") && date.allSatisfy(\.isNumber)
        }
        guard date.count == 10 else { return false }
        let characters = Array(date)
        guard characters[4] == "-", characters[7] == "-" else { return false }
        return characters.enumerated().allSatisfy { index, character in
            index == 4 || index == 7 ? character == "-" : character.isNumber
        } && date.hasPrefix("20")
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func dollars(_ tokens: Int, rate: Double) -> Double {
        Double(tokens) / 1_000_000 * rate
    }
}
