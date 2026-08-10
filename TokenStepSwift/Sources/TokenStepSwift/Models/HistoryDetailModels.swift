import Foundation

enum HistoryBreakdownPrecision: Equatable {
    case exact
    case legacyMarginals
}

struct HistoryMarginalDetail: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var totalTokens: Int
}

struct HistoryToolDetail: Identifiable, Equatable {
    var id: String { tool }
    var tool: String
    var models: [DailyAtomicUsage]

    var inputTokens: Int { models.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int { models.reduce(0) { $0 + $1.outputTokens } }
    var cacheReadTokens: Int { models.reduce(0) { $0 + $1.cacheReadTokens } }
    var cacheWriteTokens: Int { models.reduce(0) { $0 + $1.cacheWriteTokens } }
    var totalTokens: Int { models.reduce(0) { $0 + $1.totalTokens } }
}

/// A presentation model that deliberately keeps legacy tool and model totals
/// separate. Old snapshots do not contain enough information to cross-join
/// them, so this type makes inventing a relationship difficult by design.
struct HistoryDayDetailViewModel: Equatable {
    var date: String
    var totalTokens: Int
    var precision: HistoryBreakdownPrecision
    var tools: [HistoryToolDetail]
    var legacyTools: [HistoryMarginalDetail]
    var legacyModels: [HistoryMarginalDetail]

    init(row: DailyUsage) {
        date = row.date
        totalTokens = row.totalTokens

        guard let atomicUsage = row.atomicUsage else {
            precision = .legacyMarginals
            tools = []
            legacyTools = Self.sortedMarginals(row.tools)
            legacyModels = Self.sortedMarginals(row.models)
            return
        }

        precision = .exact
        legacyTools = []
        legacyModels = []
        tools = Dictionary(grouping: atomicUsage, by: \.tool)
            .map { tool, models in
                HistoryToolDetail(
                    tool: tool,
                    models: models.sorted {
                        if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                        return $0.model.localizedStandardCompare($1.model) == .orderedAscending
                    }
                )
            }
            .sorted {
                if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                return $0.tool.localizedStandardCompare($1.tool) == .orderedAscending
            }
    }

    var exactTotalTokens: Int? {
        guard precision == .exact else { return nil }
        return tools.reduce(0) { $0 + $1.totalTokens }
    }

    var exactTotalMatchesDay: Bool {
        exactTotalTokens == totalTokens
    }

    private static func sortedMarginals(_ values: [String: Int]) -> [HistoryMarginalDetail] {
        values.map { HistoryMarginalDetail(name: $0.key, totalTokens: $0.value) }
            .sorted {
                if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
