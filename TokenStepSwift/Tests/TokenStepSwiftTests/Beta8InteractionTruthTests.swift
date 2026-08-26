import XCTest
@testable import TokenStepSwift

final class Beta8InteractionTruthTests: XCTestCase {
    @MainActor
    func testTodayToolExpansionRequestSelectsTodayAndAdvancesSignal() {
        let navigation = MainWindowNavigation(section: .community)

        navigation.requestTodayToolExpansion()

        XCTAssertEqual(navigation.section, .today)
        XCTAssertEqual(navigation.todayToolExpansionRequest, 1)

        navigation.requestTodayToolExpansion()
        XCTAssertEqual(navigation.todayToolExpansionRequest, 2)
    }
}
