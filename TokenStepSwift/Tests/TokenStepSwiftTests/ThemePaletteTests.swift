import Darwin
import XCTest
@testable import TokenStepSwift

final class ThemePaletteTests: XCTestCase {
    func testBeta8ExposesNineDistinctThemes() {
        let themes = TokenStepTheme.allCases

        XCTAssertEqual(themes.count, 9)
        XCTAssertEqual(Set(themes.map(\.rawValue)).count, 9)
        XCTAssertEqual(Set(themes.map { rgbKey($0.palette.accent) }).count, 9)
    }

    func testEveryThemeColorComponentIsNormalized() {
        for theme in TokenStepTheme.allCases {
            let palette = theme.palette
            let colors = [
                palette.canvas,
                palette.surface,
                palette.accent,
                palette.accentDark,
                palette.accentSoft,
                palette.track,
                palette.lowActivity,
                palette.activity1,
                palette.activity2,
                palette.activity3,
                palette.activity4,
                palette.ring1,
                palette.ring2,
                palette.ring3,
                palette.ring4
            ]

            for color in colors {
                XCTAssertTrue((0...1).contains(color.red), "\(theme.rawValue) red")
                XCTAssertTrue((0...1).contains(color.green), "\(theme.rawValue) green")
                XCTAssertTrue((0...1).contains(color.blue), "\(theme.rawValue) blue")
            }
        }
    }

    func testDarkAccentKeepsReadableContrastOnCanvas() {
        for theme in TokenStepTheme.allCases {
            let palette = theme.palette
            XCTAssertTrue(
                contrastRatio(palette.accentDark, palette.canvas) >= 4.5,
                "\(theme.rawValue) accentDark should remain readable on its canvas"
            )
        }
    }

    private func rgbKey(_ value: TokenStepRGB) -> String {
        "\(value.red)-\(value.green)-\(value.blue)"
    }

    private func contrastRatio(_ lhs: TokenStepRGB, _ rhs: TokenStepRGB) -> Double {
        let brighter = max(relativeLuminance(lhs), relativeLuminance(rhs))
        let darker = min(relativeLuminance(lhs), relativeLuminance(rhs))
        return (brighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ value: TokenStepRGB) -> Double {
        func channel(_ component: Double) -> Double {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel(value.red)
            + 0.7152 * channel(value.green)
            + 0.0722 * channel(value.blue)
    }
}
