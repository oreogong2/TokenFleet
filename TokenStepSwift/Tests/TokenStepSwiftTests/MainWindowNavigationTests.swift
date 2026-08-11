import XCTest
@testable import TokenStepSwift

final class MainWindowNavigationTests: XCTestCase {
    func testPrimarySectionsKeepTheAppToUsageHistoryAndCommunity() {
        XCTAssertEqual(AppSection.allCases, [.today, .history, .community])
    }

    func testPopoverAgentDestinationOverridesExistingSectionWithToday() {
        let navigation = MainWindowNavigation(section: .history)

        navigation.select(PopoverAgentWorkStrip.destination)

        XCTAssertEqual(navigation.section, .today)
    }
}
