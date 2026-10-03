import XCTest

@MainActor final class HubUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        if args.contains("--ax5") {
            // モーダルもOSと同じ最大文字で確認します（親Viewだけの環境指定では不足）。
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10)); return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        func visibleText() -> Bool {
            guard element.exists, element.elementType == .staticText else { return false }
            let frame = element.frame
            return frame.minY >= 113 && frame.maxY < 768 && frame.minX >= 0 && frame.maxX <= app.frame.width
        }
        for attempt in 0..<25 {
            let midpointVisible = element.exists && element.frame.midY >= 113 && element.frame.midY < 768
            if element.exists && ((element.isHittable && midpointVisible) || visibleText()) { return }
            if element.exists && element.frame.maxY < 135 { app.swipeDown() }
            else if !element.exists && attempt >= 12 { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }
    private func tap(_ label: String, app: XCUIApplication) {
        let matches = app.buttons.matching(identifier: label)
        let button = matches.element(boundBy: max(0, matches.count - 1))
        reveal(button, app: app); button.tap()
    }
    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.firstMatch.tap() }
    private func tab(_ label: String, app: XCUIApplication) { app.tabBars.buttons[label].tap() }
    private func proof(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let text = XCTAttachment(string: app.debugDescription); text.name = name + "-elements"; text.lifetime = .keepAlways; add(text)
    }
    private func tour(_ mode: [String], prefix: String) {
        let app = launch(["--p7-preview"] + mode)
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["175"].exists); proof(app, prefix + "-home")
        tap("目標と残り", app: app); XCTAssertTrue(app.staticTexts["目標合計 2,000 kcal"].exists); proof(app, prefix + "-goal"); back(app)
        tab("その他", app: app); proof(app, prefix + "-other")
        tap("トレーニング", app: app); XCTAssertTrue(app.buttons["training-day-2026-10-02"].exists); proof(app, prefix + "-training")
        tap("種目の成績を見る", app: app); proof(app, prefix + "-grades")
        reveal(app.staticTexts["推定1RMは方式未設定のため計算していません。"], app: app); proof(app, prefix + "-grades-lower")
        back(app); back(app)
        tap("健康データと体重", app: app); tap("体重と測定履歴", app: app)
        XCTAssertTrue(app.staticTexts["68 kg"].firstMatch.exists); proof(app, prefix + "-weight")
        reveal(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "読み込み済みの最古日：")).firstMatch, app: app); proof(app, prefix + "-weight-bottom")
        back(app); back(app)
        tab("食事", app: app); XCTAssertTrue(app.staticTexts["175"].exists); proof(app, prefix + "-food")
        tap("プリセットを編集", app: app); proof(app, prefix + "-presets")
        reveal(app.buttons["カテゴリーを作成"], app: app); proof(app, prefix + "-presets-bottom"); tap("閉じる", app: app)
        tab("その他", app: app); reveal(app.links["利用条件"], app: app); proof(app, prefix + "-other-bottom")
    }
    func testLightNormalEightPages() { tour(["--light"], prefix: "light-normal") }
    func testDarkNormalEightPages() { tour(["--dark"], prefix: "dark-normal") }
    func testLightLargestTextEightPages() { tour(["--light", "--ax5"], prefix: "light-ax5") }
    func testDarkLargestTextEightPages() { tour(["--dark", "--ax5"], prefix: "dark-ax5") }
    private func largestCatalog(_ mode: String) {
        let app = launch(["--p7-preview", mode, "--ax5"])
        XCTAssertTrue(app.tabBars.buttons["食事"].waitForExistence(timeout: 10))
        tab("食事", app: app); tap("プリセットを編集", app: app)
        let name = app.staticTexts["全粒粉パン"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(name.frame.height, 30, "モーダルが最大文字になっていること")
        reveal(app.buttons["カテゴリーを作成"], app: app)
        proof(app, mode + "-native-ax5-catalog-bottom")
        tap("閉じる", app: app)
        XCTAssertTrue(app.staticTexts["175"].exists)
    }
    func testLightNativeLargestCatalog() { largestCatalog("--light") }
    func testDarkNativeLargestCatalog() { largestCatalog("--dark") }
    func testMotionReadsNativeReducedMotionSetting() {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let motionSwitch = settings.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "視差効果を減らす")).firstMatch
        if !motionSwitch.exists {
            let accessibility = settings.buttons["com.apple.settings.accessibility"]
            XCTAssertTrue(accessibility.waitForExistence(timeout: 10), settings.debugDescription)
            accessibility.tap()
            let motion = settings.staticTexts["動作"].firstMatch
            XCTAssertTrue(motion.waitForExistence(timeout: 10), settings.debugDescription)
            motion.tap()
        }
        XCTAssertTrue(motionSwitch.waitForExistence(timeout: 10), settings.debugDescription)
        let original = motionSwitch.value as? String
        XCTAssertTrue(original == "0" || original == "1")
        if original == "0" { motionSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let switchOn = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: motionSwitch)], timeout: 5) == .completed
        proof(settings, "motion-settings-on")
        let app = launch(["--p8-motion-preview", "--light"])
        let policy = app.staticTexts["motion-policy"]
        let available = policy.waitForExistence(timeout: 10)
        let nativeReduced = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "動きを減らす：オン"), object: policy)], timeout: 5) == .completed
        let sample = app.staticTexts["motion-sample"]
        let before = sample.frame
        app.buttons["押下状態を切り替える"].tap()
        let after = sample.frame
        let scale = sample.value as? String
        proof(app, "motion-native-reduced")
        app.terminate(); settings.activate()
        if original == "0", motionSwitch.value as? String == "1" { motionSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(motionSwitch.value as? String, original, "Simulatorの設定を元に戻す")
        XCTAssertTrue(switchOn && available && nativeReduced, "switchOn=\(switchOn), policy=\(policy.label)")
        XCTAssertEqual(scale, "等倍")
        XCTAssertEqual(before.width, after.width, accuracy: 0.1)
        XCTAssertEqual(before.height, after.height, accuracy: 0.1)
    }
    func testMotionReducedAndNormalPreserveActions() {
        for reduced in [false, true] {
            let app = launch(["--p8-motion-preview", "--light"] + (reduced ? ["--reduce-motion"] : []))
            let policy = app.staticTexts["motion-policy"]
            XCTAssertTrue(policy.waitForExistence(timeout: 10))
            XCTAssertEqual(policy.label, reduced ? "動きを減らす：オン" : "動きを減らす：オフ")
            tap("押下状態を切り替える", app: app)
            XCTAssertEqual(app.staticTexts["motion-sample"].value as? String, reduced ? "等倍" : "縮小")
            proof(app, reduced ? "motion-reduced" : "motion-normal")
            tap("記録する（合成）", app: app)
            XCTAssertEqual(app.staticTexts["motion-count"].label, "記録 1件")
            app.terminate()
        }
    }
    func testEmptyAndPreviousValueReviewStates() {
        var app = launch(["--p7-preview", "--empty", "--light"])
        XCTAssertTrue(app.staticTexts["目標は未設定"].waitForExistence(timeout: 10)); proof(app, "empty-home")
        tab("食事", app: app); reveal(app.staticTexts["確定した食事はありません"], app: app); proof(app, "empty-food"); app.terminate()
        app = launch(["--p7-preview", "--failure", "--pending", "--history-partial", "--dark"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10)); tab("その他", app: app)
        reveal(app.staticTexts["要確認：REVISION_CONFLICT（合成表示）"], app: app)
        XCTAssertTrue(app.staticTexts["sync-message"].label.contains("前回の確定値")); proof(app, "previous-value-and-review")
    }
    func testAnalysisDraftStaysOutsideTotalsAndConfirmationCloses() {
        let app = launch(["--p4-preview", "--no-questions", "--light"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10)); tap("写真・文章から記録", app: app); tap("解析する", app: app)
        reveal(app.buttons["確認して記録"], app: app); proof(app, "analysis-unconfirmed")
        tap("閉じる", app: app); XCTAssertTrue(app.staticTexts["175"].exists)
        tap("写真・文章から記録", app: app); tap("解析する", app: app); tap("確認して記録", app: app)
        XCTAssertFalse(app.buttons["確認して記録"].exists); reveal(app.staticTexts["架空のチキンプレート"], app: app); proof(app, "analysis-confirmed-pending")
    }
    private func openPlate(_ app: XCUIApplication) {
        tap("写真・文章から記録", app: app)
        tap("食べる前と後の2枚で記録", app: app)
    }
    func testSharedPlatePairResumesAndOnlyConfirmedDifferenceChangesTotal() {
        let app = launch(["--p4-preview", "--no-questions", "--light"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10)); openPlate(app)
        tap("合成の前写真を用意", app: app)
        XCTAssertTrue(app.staticTexts["plate-unconfirmed"].exists); proof(app, "plate-before-local")
        tap("閉じる", app: app); tap("閉じる", app: app)
        XCTAssertTrue(app.staticTexts["175"].exists)
        // 再起動しても端末内の食事中写真を再開します。保存先はPreview専用。
        app.terminate(); app.launchArguments += ["--plate-resume"]; app.launch(); openPlate(app)
        XCTAssertTrue(app.staticTexts["plate-unconfirmed"].exists)
        tap("合成の後写真を用意", app: app); tap("前後2枚を解析する", app: app)
        reveal(app.buttons["plate-item"], app: app)
        XCTAssertTrue(app.staticTexts["60g · 120 kcal"].exists); proof(app, "plate-consumed-draft")
        tap("閉じる", app: app); tap("閉じる", app: app); XCTAssertTrue(app.staticTexts["175"].exists)
        openPlate(app); tap("確認して記録", app: app)
        XCTAssertTrue(app.staticTexts["295"].waitForExistence(timeout: 10)); proof(app, "plate-confirmed-once")
        openPlate(app); reveal(app.buttons["合成の前写真を用意"], app: app); XCTAssertTrue(app.buttons["合成の前写真を用意"].exists)
        XCTAssertFalse(app.staticTexts["plate-unconfirmed"].exists); proof(app, "plate-photos-cleared")
    }
    func testSharedPlateFallbackAllHalfManualAndCancel() {
        let app = launch(["--p4-preview", "--no-questions", "--dark", "--ax5"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10)); openPlate(app)
        for (choice, expected) in [("全部食べた", "100g · 200 kcal"), ("半分くらい", "50g · 100 kcal"), ("自分で入力", "100g · 200 kcal")] {
            tap("合成の前写真を用意", app: app); tap(choice, app: app)
            reveal(app.buttons["plate-item"], app: app); XCTAssertTrue(app.staticTexts[expected].exists)
            if choice == "自分で入力" {
                reveal(app.staticTexts["各食品を自分が食べた量に編集しましたか？"], app: app)
                tap("確認して記録", app: app)
                XCTAssertTrue(app.staticTexts["確認が必要な質問へ回答してください。"].exists)
            }
            proof(app, "plate-fallback-" + choice)
            tap("一時写真を消して取消", app: app); tap("閉じる", app: app)
            XCTAssertTrue(app.staticTexts["175"].exists); openPlate(app)
            reveal(app.buttons["合成の前写真を用意"], app: app); XCTAssertTrue(app.buttons["合成の前写真を用意"].exists)
        }
    }
    func testSyncingAndHistoryProgressAtLargestText() {
        let app = launch(["--p7-preview", "--syncing", "--history-partial", "--dark", "--ax5"])
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 10))
        reveal(app.staticTexts["履歴を取り込み中"], app: app); proof(app, "history-in-progress-ax5")
        reveal(app.staticTexts["同期しています"], app: app)
        XCTAssertFalse(app.buttons["確認しています…"].isEnabled); proof(app, "syncing-disabled-ax5")
    }
    func testSelectedMotionComponentsKeepActionsInNormalAndReducedModes() {
        for reduced in [false, true] {
            let app = launch(["--p8-patterns-preview", reduced ? "--dark" : "--light"] + (reduced ? ["--reduce-motion", "--ax5"] : []))
            XCTAssertTrue(app.staticTexts["patterns-policy"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.staticTexts["patterns-policy"].label, reduced ? "装飾：停止" : "装飾：動作")
            let save = app.buttons["保存動作"]; reveal(save, app: app); save.doubleTap()
            XCTAssertTrue(app.staticTexts["保存 1件"].waitForExistence(timeout: 10)); XCTAssertTrue(app.staticTexts["同期完了"].exists)
            tap("見本のメニュー", app: app); tap("編集の見本", app: app)
            XCTAssertTrue(app.staticTexts["patterns-error"].exists); proof(app, "patterns-food-" + String(reduced))
            tap("設定", app: app)
            let toggle = app.switches["自動補正"]; reveal(toggle, app: app); toggle.tap()
            XCTAssertEqual(toggle.value as? String, "1")
            tap("増量", app: app); XCTAssertEqual(app.staticTexts["patterns-option"].label, "選択：増量"); proof(app, "patterns-settings-" + String(reduced))
            tap("進捗", app: app); tap("リングを満たす", app: app)
            tap("Cycleの9枠を完了", app: app)
            reveal(app.staticTexts["patterns-cycle-count"], app: app); XCTAssertEqual(app.staticTexts["patterns-cycle-count"].label, "Cycle 9 / 9")
            proof(app, "patterns-progress-" + String(reduced)); app.terminate()
        }
    }
    func testAnimatedFoodHistoryEditsPreserveTotalsAndPendingCount() {
        let app = launch(["--p4-preview", "--light"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10))
        tap("昼食", app: app); tap("朝食", app: app)
        tap("全粒粉パンを追加", app: app)
        XCTAssertTrue(app.staticTexts["追加しました · 端末に保存済み"].exists)
        tap("取り消す", app: app); XCTAssertTrue(app.staticTexts["175"].exists)
        tap("履歴", app: app); tap("全粒粉パン・ゆで卵のメニュー", app: app)
        tap("量・日付を変更", app: app); tap("量を0.5倍増やす", app: app)
        XCTAssertEqual(app.textFields["food-edit-factor"].value as? String, "1.5"); proof(app, "motion-quantity-sheet")
        tap("保存", app: app); back(app)
        tap("架空の保存結果を受信", app: app)
        reveal(app.staticTexts["262.5"], app: app); XCTAssertTrue(app.staticTexts["262.5"].exists)
        XCTAssertFalse(app.staticTexts["保存の送信待ち"].exists); proof(app, "motion-food-confirmed")
    }
    func testAnimatedHomeNavigationChartsAndTrainingRows() {
        let app = launch(["--p7-preview", "--light"])
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 10))
        tap("目標と残り", app: app)
        let info = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "説明：")).firstMatch
        reveal(info, app: app); info.tap(); proof(app, "motion-goal-explanation")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.35)).tap(); back(app)
        reveal(app.buttons["health-weight-link"], app: app); app.buttons["health-weight-link"].tap()
        tap("7日", app: app); tap("全期間", app: app); proof(app, "motion-weight-chart"); back(app)
        tap("カレンダーとCycleを見る", app: app)
        reveal(app.otherElements["motion-cycle"], app: app); proof(app, "motion-real-cycle")
        tap("種目の成績を見る", app: app); tap("90日", app: app); proof(app, "motion-training-chart"); back(app)
        tap("training-session-00000000-0000-4000-a000-000000000003", app: app)
        XCTAssertTrue(app.staticTexts["セット1 · 55 kg × 8回"].exists); proof(app, "motion-training-set-rows")
    }
}
