import XCTest

@MainActor final class CalendarLayoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCalendarNormalText() { calendar(largest: false) }
    func testCalendarLargestText() { calendar(largest: true) }

    private func launch(_ args: [String], largest: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        if largest { app.launchArguments += ["--ax5", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
    }

    private func calendar(largest: Bool) {
        let app = launch(["--p3-preview"], largest: largest)
        let day = app.buttons["training-day-2026-10-02"]
        XCTAssertTrue(day.waitForExistence(timeout: 15))
        XCTAssertTrue(day.label.contains("Push") && day.label.contains("Pull"))
        attach(app, largest ? "calendar-largest-top" : "calendar-normal-top")
        let first = app.buttons["training-day-2026-10-01"]
        reveal(first, app: app); first.tap()
        attach(app, largest ? "calendar-largest-selected" : "calendar-normal-selected")
        let next = app.buttons["次の月"]
        reveal(next, app: app); next.tap()
        XCTAssertTrue(app.buttons["training-day-2026-11-01"].waitForExistence(timeout: 5))
        app.buttons["前の月"].tap()
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        reveal(day, app: app); day.tap()
        let count = app.staticTexts["· 3セッション"]
        reveal(count, app: app)
        attach(app, largest ? "calendar-largest-counts" : "calendar-normal-counts")
        XCTAssertTrue(app.staticTexts["2日"].exists)
        let session = app.buttons["training-session-00000000-0000-4000-a000-000000000004"]
        reveal(session, app: app); session.tap()
        XCTAssertTrue(app.staticTexts["セット1 · 自重 × 8回"].waitForExistence(timeout: 5), app.debugDescription)
        attach(app, largest ? "calendar-largest-session" : "calendar-normal-session")
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
