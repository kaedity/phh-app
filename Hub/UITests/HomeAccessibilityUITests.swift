import XCTest

@MainActor final class HomeAccessibilityUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testNormalLight() { check(largest: false, dark: false) }
    func testNormalDark() { check(largest: false, dark: true) }
    func testLargestLight() { check(largest: true, dark: false) }
    func testLargestDark() { check(largest: true, dark: true) }
    func testLargestGoalNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--p7-preview", "--ax5", "--dark"]
        app.launch()
        XCTAssertTrue(app.buttons["hub-tab-home"].waitForExistence(timeout: 15))
        let goal = app.buttons["目標の内訳"]
        reveal(goal, app: app)
        attach(app, "home-goal-largest")
        goal.tap()
        XCTAssertTrue(app.navigationBars["目標の内訳"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["hub-tab-home"].exists)
    }
    func testOtherSharedRowNormal() { otherSharedRow(largest: false) }
    func testOtherSharedRowLargest() { otherSharedRow(largest: true) }
    private func otherSharedRow(largest: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--p7-preview", "--dark"] + (largest ? ["--ax5"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["hub-tab-other"].waitForExistence(timeout: 15))
        app.buttons["hub-tab-other"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "食事の記録設定")).firstMatch
        reveal(row, app: app)
        let title = app.staticTexts["食事の記録設定"].firstMatch
        XCTAssertTrue(title.exists)
        XCTAssertGreaterThanOrEqual(title.frame.minX, 18)
        XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.width-18)
        if largest { XCTAssertGreaterThan(title.frame.width, 140) }
        else { XCTAssertLessThan(title.frame.height, title.frame.width) }
        attach(app, "combined-other-shared-row-\(largest)")
        row.tap()
        XCTAssertTrue(app.navigationBars["食事の記録設定"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["hub-tab-other"].exists)
    }
    private func check(largest: Bool, dark: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--p7-preview", dark ? "--dark" : "--light"] + (largest ? ["--ax5"] : [])
        app.launch()
        let weight = app.buttons["health-weight-link"]
        XCTAssertTrue(app.buttons["hub-tab-home"].waitForExistence(timeout: 15))
        reveal(weight, app: app)
        attach(app, "home-health-\(largest)-\(dark)")
        let ax = XCTAttachment(string: app.debugDescription); ax.name = "home-AX-\(largest)-\(dark)"; ax.lifetime = .keepAlways; add(ax)
        let title = app.staticTexts["最新体重"].firstMatch
        XCTAssertTrue(title.exists)
        print("PHH_HOME_GEOMETRY weight=\(weight.frame) label=\(title.frame)")
        XCTAssertTrue(app.staticTexts["68.0"].firstMatch.exists)
        if largest {
            XCTAssertGreaterThan(app.staticTexts["68.0"].firstMatch.frame.width, 40, "complete weight digits need room to render")
            XCTAssertGreaterThan(weight.frame.width, app.frame.width * 0.75)
            XCTAssertLessThan(title.frame.height, title.frame.width, "label must not become a vertical column of individual glyphs")
        } else {
            let sleep = app.staticTexts["睡眠"].firstMatch
            XCTAssertTrue(sleep.exists)
            XCTAssertGreaterThan(sleep.frame.minX, title.frame.maxX)
            XCTAssertEqual(sleep.frame.minY, title.frame.minY, accuracy: 2)
        }
        weight.tap()
        XCTAssertTrue(app.navigationBars["体重"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        for name in ["睡眠", "歩数", "活動"] {
            let label = app.staticTexts[name].firstMatch
            reveal(label, app: app)
            XCTAssertTrue(label.isHittable, name)
            if largest { XCTAssertLessThan(label.frame.height, label.frame.width, name) }
            attach(app, "home-\(name)-\(largest)-\(dark)")
            label.tap()
            XCTAssertTrue(app.navigationBars["健康データ"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.firstMatch.tap()
        }
        let cycle = app.buttons["カレンダーとCycleを見る"]
        reveal(cycle, app: app)
        attach(app, "home-cycle-\(largest)-\(dark)")
        cycle.tap()
        XCTAssertTrue(app.buttons["training-day-2026-10-02"].waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<18 {
            if element.exists, element.isHittable, element.frame.midY > 100, element.frame.midY < app.frame.height-110 { return }
            if element.exists, element.frame.midY < 100 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name=name; a.lifetime = .keepAlways; add(a)
    }
}
