import XCTest

final class SottoUITests: XCTestCase {
    func testLaunchShowsOnboarding() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
    }
}
