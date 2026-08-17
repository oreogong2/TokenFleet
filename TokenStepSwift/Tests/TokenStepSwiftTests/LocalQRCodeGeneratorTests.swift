import XCTest
@testable import TokenStepSwift

final class LocalQRCodeGeneratorTests: XCTestCase {
    func testMatricesMatchIndependentNayukiFixturesAcrossSupportedVersions() throws {
        let cases: [(String, UInt64)] = [
            (
                "https://demo.tokenfleet.example/rank/p/outside-100",
                0x6BCB55AF3FB35EC5
            ),
            (
                "https://example.com/rank/p/"
                    + String(repeating: "a", count: 128)
                    + "?tool="
                    + String(repeating: "b", count: 128),
                0x25A02C10B46CA925
            ),
            (
                "https://example.com/rank?tool="
                    + String(repeating: "模", count: 128)
                    + "&model="
                    + String(repeating: "型", count: 128),
                0x72DA9F4577B4C559
            )
        ]

        for (value, expected) in cases {
            let matrix = try LocalQRCodeGenerator.matrix(for: value)
            XCTAssertEqual(fnv1a64(matrix), expected)
        }
    }

    private func fnv1a64(_ matrix: [[Bool]]) -> UInt64 {
        let bytes = matrix
            .map { row in row.map { $0 ? "1" : "0" }.joined() }
            .joined(separator: "\n")
            .utf8
        return bytes.reduce(UInt64(0xCBF29CE484222325)) { hash, byte in
            (hash ^ UInt64(byte)) &* UInt64(0x100000001B3)
        }
    }
}
