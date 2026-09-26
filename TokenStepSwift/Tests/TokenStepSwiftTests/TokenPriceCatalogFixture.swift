import Foundation
@testable import TokenStepSwift

// Synthetic prices are a protocol fixture, not provider price evidence.
enum TokenPriceCatalogFixture {
    static var payload: Data {
        get throws {
            try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Fixtures/server-price-catalog-v1.json"))
        }
    }
    static var context: TokenPriceCatalogCache.Context {
        get throws {
            TokenPriceCatalogCache.Context(origin: "https://community.example.com", catalog: try ServerTokenPriceCatalog.decode(payload))
        }
    }
    static func replacing(_ changes: [String: Any]) throws -> Data {
        var body = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        body.removeValue(forKey: "version")
        body.merge(changes, uniquingKeysWith: { _, new in new })
        let canonical = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        body["version"] = ServerTokenPriceCatalog.digest(canonical)
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
