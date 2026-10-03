import XCTest

@MainActor final class HistoryLayoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testWeightNormalText() { weight(largest: false) }
    func testWeightLargestText() { weight(largest: true) }

    private func launch(_ args: [String], largest: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        if largest { app.launchArguments += ["--ax5", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
    }

    private func weight(largest: Bool) {
        let app = launch(["--p6-preview", "--weight"], largest: largest)
        XCTAssertTrue(app.staticTexts["測定履歴"].waitForExistence(timeout: 15))
        let value = app.staticTexts["68.2 kg"].firstMatch
        reveal(value, app: app)
        attach(app, largest ? "weight-largest-history" : "weight-normal-history")
        XCTAssertLessThan(value.frame.height, 100, "Weight and unit must stay together on one line")
        XCTAssertGreaterThanOrEqual(value.frame.minX, 0)
        XCTAssertLessThanOrEqual(value.frame.maxX, app.frame.width)
    }

    private func reveal(_ target: XCUIElement, app: XCUIApplication) {
        for _ in 0..<18 {
            if target.exists, target.isHittable, target.frame.minY > 110, target.frame.maxY < app.frame.maxY - 60 { return }
            if target.exists, target.frame.minY < 110 { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(target.exists && target.isHittable, app.debugDescription)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let elements = XCTAttachment(string: app.debugDescription)
        elements.name = name + "-elements"; elements.lifetime = .keepAlways; add(elements)
    }
}
