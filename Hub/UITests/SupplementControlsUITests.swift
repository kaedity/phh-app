import XCTest

@MainActor final class SupplementControlsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testNormalControls() { controls(largest: false, excluded: false) }
    func testLargestControls() { controls(largest: true, excluded: false) }
    func testNormalExcludedControls() { controls(largest: false, excluded: true) }
    func testLargestExcludedControls() { controls(largest: true, excluded: true) }

    private func controls(largest: Bool, excluded: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--p5-preview"]
        if excluded { app.launchArguments += ["--excluded-supplement"] }
        if largest { app.launchArguments += ["--ax5", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let link = app.buttons["カテゴリー内のサプリ・自動計上"]
        reveal(link, app: app); link.tap()
        let change = app.buttons["この日だけ量を変更"]
        let action = app.buttons[excluded ? "服用を報告" : "飲まなかった"]
        reveal(change, app: app)
        XCTAssertTrue(action.exists)
        attach(app, "controls-before-\(largest)-excluded-\(excluded)")
        if largest { XCTAssertLessThanOrEqual(change.frame.maxY, action.frame.minY, "文字拡大時は操作ボタンを縦に流す（DESIGN 2.6）") }
        else { XCTAssertEqual(change.frame.midY, action.frame.midY, accuracy: 2) }
        reveal(action, app: app); action.tap()
        XCTAssertTrue(app.staticTexts["端末に保存しました・同期待ち"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["目標・サプリの変更"].exists)
        // The UI retains confirmed rows while the mutation waits in the Outbox.
        XCTAssertTrue(app.staticTexts[excluded ? "この日は除外" : "予定から自動計上・服用確認なし"].exists)
        attach(app, "controls-queued-\(largest)-excluded-\(excluded)")
        reveal(change, app: app); change.tap()
        XCTAssertTrue(app.textFields["粒"].waitForExistence(timeout: 5))
    }
    private func reveal(_ target: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        for _ in 0..<18 {
            if target.exists, target.isHittable, target.frame.minY > 110, target.frame.maxY < app.frame.maxY - 60 { return }
            if target.exists, target.frame.minY < 110 { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(target.exists && target.isHittable, app.debugDescription)
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let elements = XCTAttachment(string: app.debugDescription); elements.name = name + "-elements"; elements.lifetime = .keepAlways; add(elements)
    }
}
