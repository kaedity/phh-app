import XCTest
import UIKit

@MainActor final class PFCAppearanceUITests: XCTestCase {
    func testSavedAppearanceIgnoresLiveSystemChangesNormalRoot() throws {
        // 外部の外観操作は専用Simulatorで調整して実行する。通常の--uiでは待たない。
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHH_EXPECT_EXTERNAL_APPEARANCE_SWITCH"] == "1")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHH_ISOLATED_NORMAL_ROOT"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(waitForHome(app))
        app.buttons["hub-tab-other"].tap()
        app.buttons["ライトモード"].tap()
        app.buttons["hub-tab-home"].tap()
        XCTAssertGreaterThan(backgroundBrightness(app), 0.8)
        print("PHH_LIVE_READY_DARK")
        Thread.sleep(forTimeInterval: 20)
        XCTAssertGreaterThan(backgroundBrightness(app), 0.8)
        attach(app, "app-light-system-dark")
        app.buttons["hub-tab-other"].tap()
        app.buttons["ダークモード"].tap()
        app.buttons["hub-tab-home"].tap()
        XCTAssertLessThan(backgroundBrightness(app), 0.2)
        print("PHH_LIVE_READY_LIGHT")
        Thread.sleep(forTimeInterval: 20)
        XCTAssertLessThan(backgroundBrightness(app), 0.2)
        attach(app, "app-dark-system-light")
    }

    private func waitForHome(_ app: XCUIApplication) -> Bool {
        // The current main uses custom tabs; earlier roots use UITabBar.
        app.buttons["hub-tab-home"].waitForExistence(timeout: 10)
            || app.tabBars.buttons["ホーム"].waitForExistence(timeout: 5)
    }

    private func backgroundBrightness(_ app: XCUIApplication) -> Double {
        guard let image = app.screenshot().image.cgImage else { return -1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let rendered = pixel.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // x=10 is outside the cards and text in the ordinary home screen.
            context.draw(image, in: CGRect(x: -10, y: -300, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard rendered else { return -1 }
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }

    func testLargestTextManualAdjustment() {
        let app = largestPlanning()
        tap("目標と残り", app: app)
        for number in ["100", "50", "250"] {
            let nutrient = app.staticTexts[number].firstMatch
            XCTAssertTrue(nutrient.exists)
            XCTAssertLessThan(nutrient.frame.height, 100, "PFC digits must stay on one line")
        }
        reveal(app.staticTexts["250"].firstMatch, app: app)
        attach(app, "largest-goal")
        tap("この日の手動調整", app: app)
        let reason = app.textFields["調整の理由"]
        reveal(reason, app: app); reason.tap(); reason.typeText("架空の調整")
        let energy = app.textFields["kcal"]
        reveal(energy, app: app); energy.tap(); energy.typeText("125")
        let save = app.buttons["調整を端末へ保存"]
        reveal(save, app: app)
        attach(app, "largest-manual-before-save")
        save.tap()
        XCTAssertTrue(app.staticTexts["端末に保存しました・同期待ち"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "largest-manual-saved")
    }

    func testLargestTextSupplementAmount() {
        let app = largestPlanning()
        tap("カテゴリー内のサプリ・自動計上", app: app)
        XCTAssertTrue(app.staticTexts["架空のビタミン"].firstMatch.waitForExistence(timeout: 5))
        attach(app, "largest-supplement-list")
        tap("この日だけ量を変更", app: app)
        let amount = app.textFields["粒"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5), app.debugDescription)
        amount.tap()
        let previous = amount.value as? String ?? ""
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + "3")
        XCTAssertEqual(amount.value as? String, "3")
        let save = app.buttons["この日だけ変更を保存"]
        reveal(save, app: app)
        attach(app, "largest-supplement-before-save")
        save.tap()
        XCTAssertTrue(app.staticTexts["端末に保存しました・同期待ち"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "largest-supplement-saved")
    }

    private func largestPlanning() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--p5-preview", "--ax5", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["架空データ · 通信なし · 食事2200 kcal"].waitForExistence(timeout: 15))
        return app
    }

    private func tap(_ label: String, app: XCUIApplication) {
        let target = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        reveal(target, app: app); target.tap()
    }

    private func reveal(_ target: XCUIElement, app: XCUIApplication) {
        for _ in 0..<15 {
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 12 : app.frame.maxY - 60
            if target.exists, target.isHittable, target.frame.minY > 100, target.frame.maxY < bottom { return }
            if target.exists, target.frame.minY < 100 { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(target.exists && target.isHittable, app.debugDescription)
    }

    func testSystemAppearanceGoalAndEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // No --light/--dark override: use the saved app appearance (initially dark).
        app.launchArguments = ["--p5-preview", "--goal"]
        app.launch()
        XCTAssertTrue(app.staticTexts["1日の目標摂取カロリー"].waitForExistence(timeout: 15))
        for label in ["P", "F", "C"] {
            XCTAssertTrue(app.staticTexts[label].firstMatch.exists)
        }
        attach(app, "system-appearance-goal")
        let fixed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "固定目標")).firstMatch
        XCTAssertTrue(fixed.waitForExistence(timeout: 5), app.debugDescription)
        fixed.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "system-appearance-editor")
        // Normal startup may restore configured credentials. Only the explicitly
        // isolated, empty-config Simulator can exercise that part of this test.
        guard ProcessInfo.processInfo.environment["PHH_ISOLATED_NORMAL_ROOT"] == "1" else { return }
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(waitForHome(app))
        attach(app, "system-appearance-normal-root")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
