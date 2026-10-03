import XCTest

@MainActor final class RecentSetsLayoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testRecentNormalText() { recent(largest: false) }
    func testRecentLargestText() { recent(largest: true) }

    private func launch(_ args: [String], largest: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        if largest { app.launchArguments += ["--ax5", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
    }

    private func recent(largest: Bool) {
        let app = launch(["--p3-preview", "--grades"], largest: largest)
        XCTAssertTrue(app.staticTexts["最近のセット"].waitForExistence(timeout: 15))
        let value = app.staticTexts["60 kg × 5回"].firstMatch
        reveal(value, app: app)
        attach(app, largest ? "recent-largest" : "recent-normal")
        print("RECENT_VALUE_FRAME \(value.frame)")
        XCTAssertLessThan(value.frame.height, 100, "Weight and repetitions must stay together")
        XCTAssertGreaterThanOrEqual(value.frame.minX, 0)
        XCTAssertLessThanOrEqual(value.frame.maxX, app.frame.width)
        value.tap()
        XCTAssertTrue(app.staticTexts["この確定セットがグラフの点の根拠です。"].waitForExistence(timeout: 5), app.debugDescription)
        // Existing synthetic fixture set 14: bench press, set 2, 60 kg × 5.
        XCTAssertTrue(app.staticTexts["セット2 · 60 kg × 5回"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["ベンチプレス"].exists, app.debugDescription)
        attach(app, largest ? "recent-largest-evidence" : "recent-normal-evidence")
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
