import Foundation
import XCTest
@testable import TokenStepSwift

final class CollectorPerformanceTests: XCTestCase {
    func testCollectorSubprocessesUseUtilityQualityOfService() {
        XCTAssertEqual(DataService.collectorHelperQualityOfServiceForTests(), .utility)
        XCTAssertEqual(UsageCollector.sqliteJSONQualityOfServiceForTests(), .utility)
    }

    func testRecorderCapturesPerSourceFilesBytesAndLoggerFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenFleetPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let input = directory.appendingPathComponent("fixture.jsonl")
        try Data(repeating: 0x61, count: 4_096).write(to: input)

        let recorder = CollectorPerformanceRecorder()
        recorder.measureForTests(source: "Fixture Agent", inputURLs: [input])

        let source = try XCTUnwrap(recorder.sources.first)
        XCTAssertEqual(source.source, "Fixture Agent")
        XCTAssertEqual(source.files, 1)
        XCTAssertEqual(source.bytes, 4_096)
        XCTAssertEqual(source.status, "ok")
        XCTAssertFalse(source.skipped)
        XCTAssertTrue(source.elapsedMilliseconds >= 0)

        let line = try CollectorPerformanceLogger.encodedLine(
            outcome: "updated",
            totalElapsedMilliseconds: 123,
            peakRSSBytes: 45_678,
            sources: recorder.sources,
            finishedAt: Date(timeIntervalSince1970: 1_784_610_000)
        )
        let decoded = try JSONDecoder().decode(
            CollectorRunPerformanceLog.self,
            from: Data(line.dropLast())
        )
        XCTAssertEqual(decoded.event, "collector_run")
        XCTAssertEqual(decoded.outcome, "updated")
        XCTAssertEqual(decoded.totalElapsedMilliseconds, 123)
        XCTAssertEqual(decoded.peakRSSBytes, 45_678)
        XCTAssertEqual(decoded.sources, recorder.sources)
    }

    func testUnchangedCollectionStillLogsEveryKnownSourceAsSkipped() {
        let recorder = CollectorPerformanceRecorder()
        recorder.recordSkippedSources([
            "Codex": SourceInfo(status: "ok", files: 3, records: 4),
            "Hermes Agent": SourceInfo(status: "missing_db", files: 0, records: 0)
        ])

        XCTAssertEqual(recorder.sources.map(\.source), ["Codex", "Hermes Agent"])
        XCTAssertTrue(recorder.sources.allSatisfy(\.skipped))
        XCTAssertEqual(recorder.sources.map(\.elapsedMilliseconds), [0, 0])
        XCTAssertEqual(recorder.sources.map(\.bytes), [0, 0])
    }
}
