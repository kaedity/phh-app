import XCTest

@MainActor final class PlanningLanguageUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCopyNormalText() { copy(largest: false) }
    func testCopyLargestText() { copy(largest: true) }

    private func launch(_ args: [String], largest: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        if largest { app.launchArguments += ["--ax5", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
    }

    private func copy(largest: Bool) {
        let app = launch(["--p5-preview", "--frozen-overview"], largest: largest)
        let state = app.staticTexts["確定済み · 過去日の目標"]
        XCTAssertTrue(state.waitForExistence(timeout: 15))
        reveal(state, app: app)
        attach(app, largest ? "frozen-largest" : "frozen-normal")
        assertNoInternalWords(app)
        let link = app.buttons["カテゴリー内のサプリ・自動計上"]
        reveal(link, app: app); link.tap()
        let plan = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "日量 2 · 適用")).firstMatch
        reveal(plan, app: app)
        attach(app, largest ? "supplement-plan-largest" : "supplement-plan-normal")
        XCTAssertEqual(plan.label, "日量 2 · 適用 2026-10-01〜継続")
        assertNoInternalWords(app)
        XCTAssertTrue(app.staticTexts["架空のビタミン"].firstMatch.exists)
    }

    private func assertNoInternalWords(_ app: XCUIApplication) {
        let terms = ["凍結済み", "商品版", "予定版"]
        for term in terms {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", term)).firstMatch.exists)
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", term)).firstMatch.exists)
        }
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
