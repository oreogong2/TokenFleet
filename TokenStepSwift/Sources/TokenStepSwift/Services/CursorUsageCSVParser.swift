import Foundation

struct CursorUsageCSVRecord: Codable, Equatable {
    var timestamp: String
    var kind: String
    var model: String
    var maxMode: Bool
    var inputTokens: Int
    var cacheWriteTokens: Int
    var cacheReadTokens: Int
    var outputTokens: Int
    var reportedTotalTokens: Int
    var costUSD: Double

    var exactTotalTokens: Int {
        inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens
    }

    var deduplicationKey: String {
        [
            timestamp,
            kind,
            model,
            maxMode ? "1" : "0",
            String(inputTokens),
            String(cacheWriteTokens),
            String(cacheReadTokens),
            String(outputTokens),
            String(reportedTotalTokens),
            String(costUSD.bitPattern)
        ].joined(separator: "\u{1F}")
    }
}

enum CursorUsageTimestamp {
    static func date(from value: String) -> Date? {
        if let date = isoFormatterWithFractional.date(from: value) {
            return date
        }
        if let date = isoFormatter.date(from: value) {
            return date
        }
        return dateOnlyFormatter.date(from: value)
    }

    private static let timezone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
}

struct CursorUsageImportSummary: Equatable {
    var importedRecords: Int
    var addedRecords: Int
    var totalRecords: Int
}

enum CursorUsageImportError: LocalizedError {
    case invalidEncoding
    case unsupportedOrEmptyExport
    case unreadableArchive

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return L("Cursor CSV 不是有效的 UTF-8 文件")
        case .unsupportedOrEmptyExport:
            return L("没有找到可用的 Cursor usage 记录")
        case .unreadableArchive:
            return L("已有 Cursor 导入数据无法读取")
        }
    }
}

enum CursorUsageImportStore {
    private static let schemaVersion = 1

    static func importCSV(
        from sourceURL: URL,
        archiveURL: URL = AppPaths.cursorUsageImportJSON
    ) throws -> CursorUsageImportSummary {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CursorUsageImportError.invalidEncoding
        }
        let imported = CursorUsageCSVParser.parse(text)
        guard !imported.isEmpty else {
            throw CursorUsageImportError.unsupportedOrEmptyExport
        }

        var merged: [String: CursorUsageCSVRecord] = [:]
        for record in try existingRecords(at: archiveURL) {
            merged[record.deduplicationKey] = record
        }
        let previousCount = merged.count
        for record in imported {
            merged[record.deduplicationKey] = record
        }

        let records = merged.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.deduplicationKey < $1.deduplicationKey
        }
        let archive = CursorUsageImportArchive(
            schemaVersion: schemaVersion,
            importedAt: ISO8601DateFormatter().string(from: Date()),
            records: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(archive)
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(to: archiveURL, options: .atomic)

        return CursorUsageImportSummary(
            importedRecords: imported.count,
            addedRecords: records.count - previousCount,
            totalRecords: records.count
        )
    }

    static func removeImport(archiveURL: URL = AppPaths.cursorUsageImportJSON) throws {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return }
        try FileManager.default.removeItem(at: archiveURL)
    }

    static func recordCount(archiveURL: URL = AppPaths.cursorUsageImportJSON) -> Int? {
        try? existingRecords(at: archiveURL).count
    }

    private static func existingRecords(at archiveURL: URL) throws -> [CursorUsageCSVRecord] {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: archiveURL)
            let archive = try JSONDecoder().decode(CursorUsageImportArchive.self, from: data)
            guard archive.schemaVersion == schemaVersion else {
                throw CursorUsageImportError.unreadableArchive
            }
            return archive.records
        } catch let error as CursorUsageImportError {
            throw error
        } catch {
            throw CursorUsageImportError.unreadableArchive
        }
    }
}

private struct CursorUsageImportArchive: Codable {
    var schemaVersion: Int
    var importedAt: String
    var records: [CursorUsageCSVRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case importedAt = "imported_at"
        case records
    }
}

enum CursorUsageCSVParser {
    static func parse(_ text: String) -> [CursorUsageCSVRecord] {
        let rows = csvRows(text)
        guard let header = rows.first, rows.count > 1 else { return [] }

        var columnIndex: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            let normalized = name
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            columnIndex[normalized] = index
        }
        let requiredNames = [
            "Date",
            "Model",
            "Input (w/ Cache Write)",
            "Input (w/o Cache Write)",
            "Cache Read",
            "Output Tokens",
            "Total Tokens",
            "Cost"
        ]
        guard requiredNames.allSatisfy({ columnIndex[$0] != nil }) else { return [] }

        func field(_ name: String, in row: [String]) -> String {
            guard let index = columnIndex[name], row.indices.contains(index) else { return "" }
            return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return rows.dropFirst().compactMap { row in
            let timestamp = field("Date", in: row)
            let model = field("Model", in: row)
            guard !timestamp.isEmpty,
                  !model.isEmpty,
                  CursorUsageTimestamp.date(from: timestamp) != nil
            else { return nil }

            let inputWithCacheWrite = nonNegativeInteger(field("Input (w/ Cache Write)", in: row))
            let inputWithoutCacheWrite = nonNegativeInteger(field("Input (w/o Cache Write)", in: row))
            let cacheRead = nonNegativeInteger(field("Cache Read", in: row))
            let output = nonNegativeInteger(field("Output Tokens", in: row))
            let reportedTotal = nonNegativeInteger(field("Total Tokens", in: row))
            let exactTotal = inputWithoutCacheWrite
                + max(0, inputWithCacheWrite - inputWithoutCacheWrite)
                + cacheRead
                + output
            guard max(exactTotal, reportedTotal) > 0 else { return nil }

            return CursorUsageCSVRecord(
                timestamp: timestamp,
                kind: field("Kind", in: row).isEmpty ? "unknown" : field("Kind", in: row),
                model: model,
                maxMode: field("Max Mode", in: row).lowercased() == "yes",
                inputTokens: inputWithoutCacheWrite,
                cacheWriteTokens: max(0, inputWithCacheWrite - inputWithoutCacheWrite),
                cacheReadTokens: cacheRead,
                outputTokens: output,
                reportedTotalTokens: reportedTotal,
                costUSD: decimal(field("Cost", in: row))
            )
        }
    }

    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        func finishField() {
            row.append(field)
            field = ""
        }
        func finishRow() {
            finishField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                rows.append(row)
            }
            row = []
        }

        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if inQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = text.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                finishField()
            } else if (character == "\n" || character == "\r"), !inQuotes {
                if character == "\r" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\n" {
                        index = next
                    }
                }
                finishRow()
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            finishRow()
        }
        return rows
    }

    private static func nonNegativeInteger(_ value: String) -> Int {
        max(0, Int(value.replacingOccurrences(of: ",", with: "")) ?? 0)
    }

    private static func decimal(_ value: String) -> Double {
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Double(cleaned) ?? 0
    }
}
