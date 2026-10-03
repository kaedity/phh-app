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
            guard element.exists else {
                if attempt >= 12 { app.swipeDown() } else { app.swipeUp() }
                continue
            }
            let frame = element.frame
            let isControl = element.elementType == .button || element.elementType == .switch
            let insideViewport = isControl ? frame.minY >= 113 && frame.maxY < 768 : frame.midY >= 113 && frame.midY < 768
            if element.exists && ((element.isHittable && insideViewport) || visibleText()) { return }
            if element.exists && element.frame.maxY < 135 { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }
    private func tap(_ label: String, app: XCUIApplication) {
        if ["プリセットを編集", "並びを固定・変更", "食事の記録設定", "記録する日を選ぶ"].contains(label), !app.buttons[label].exists, app.buttons["検索と記録の設定"].exists { app.buttons["検索と記録の設定"].tap() }
        let matches = app.buttons.matching(identifier: label)
        let button = matches.element(boundBy: max(0, matches.count - 1))
        reveal(button, app: app); button.tap()
    }
    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.firstMatch.tap() }
    private func tab(_ label: String, app: XCUIApplication) {
        let key = ["ホーム":"home", "食事":"food", "その他":"other"][label] ?? label
        let custom=app.buttons["hub-tab-"+key]
        if custom.exists { custom.tap() } else { app.tabBars.buttons[label].tap() }
    }
    private func proof(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let text = XCTAttachment(string: app.debugDescription); text.name = name + "-elements"; text.lifetime = .keepAlways; add(text)
    }
    private func tour(_ mode: [String], prefix: String) {
        let app = launch(["--p7-preview"] + mode)
        XCTAssertTrue(app.buttons["hub-tab-home"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["hub-tab-home"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["hub-tab-home"].waitForExistence(timeout: 10))
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
    func testFoodFiveSecondUndoRestoresChangesAndExpiryKeepsSavedRecord() {
        let app = launch(["--p4-preview", "--light"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10))
        func undoNow() {
            let matches=app.buttons.matching(identifier: "food-undo")
            let undo=matches.element(boundBy: max(0, matches.count-1))
            XCTAssertTrue(undo.waitForExistence(timeout: 2)); undo.tap()
        }
        tap("全粒粉パンを追加", app: app); undoNow()
        XCTAssertTrue(app.staticTexts["175"].exists)
        tap("履歴", app: app); tap("全粒粉パン・ゆで卵のメニュー", app: app)
        tap("量・日付を変更", app: app); tap("2倍", app: app); tap("保存", app: app); undoNow()
        XCTAssertTrue(app.staticTexts["175"].exists); proof(app, "undo-quantity-restored")
        tap("取消", app: app); tap("この食事を取り消す", app: app); undoNow()
        XCTAssertTrue(app.staticTexts["175"].exists); proof(app, "undo-deletion-restored")
        back(app); tap("全粒粉パンを追加", app: app)
        XCTAssertTrue(app.buttons["food-undo"].waitForExistence(timeout: 2))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["food-undo"])], timeout: 8), .completed)
        reveal(app.staticTexts["275"], app: app); XCTAssertTrue(app.staticTexts["275"].exists)
        proof(app, "undo-expired-record-retained")
    }
    func testNewFoodQuantityUsesPreviousUnitValueAndMissingUnitStaysBlank() {
        let app = launch(["--p4-preview", "--light", "--numeric-reset"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10))
        tap("プリセットを編集", app: app); tap("食品を追加", app: app)
        let quantity=app.textFields["基準量"]
        XCTAssertEqual(quantity.value as? String, quantity.placeholderValue)
        app.textFields["食品名"].tap(); app.textFields["食品名"].typeText("架空の前回値試験")
        quantity.tap(); quantity.typeText("3"); tap("保存", app: app)
        tap("食品を追加", app: app)
        XCTAssertEqual(Double(quantity.value as? String ?? ""), 3)
        let unit=app.textFields["単位（個・gなど）"]
        unit.tap(); unit.typeText(XCUIKeyboardKey.delete.rawValue + "g")
        XCTAssertEqual(quantity.value as? String, quantity.placeholderValue)
        proof(app, "numeric-previous-unit-and-blank")
        tap("閉じる", app: app); tap("閉じる", app: app)
        XCTAssertTrue(app.staticTexts["175"].exists)
    }
    func testUnusualMealQuantityWarnsOnceAndCanSaveThenOpenDaySettings() {
        let app = launch(["--p4-preview", "--light"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10))
        let edit = app.buttons.matching(identifier: "量・日付を変更").firstMatch
        reveal(edit, app: app); edit.tap()
        let factor=app.textFields["food-edit-factor"]
        for _ in 0..<8 { tap("量を0.5倍増やす", app: app) }
        XCTAssertEqual(Double(factor.value as? String ?? ""), 5)
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.alerts["量がいつもより大きくなっています"].waitForExistence(timeout: 3))
        app.alerts.buttons["入力に戻る"].tap()
        XCTAssertTrue(factor.exists)
        tap("保存", app: app)
        app.alerts.buttons["この量で保存"].tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: factor)], timeout: 5), .completed)
        let total=app.staticTexts.matching(identifier: "875").firstMatch
        reveal(total, app: app); XCTAssertTrue(total.exists)
        proof(app, "unusual-quantity-confirmed-once")
        tap("食事の記録設定", app: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "food-cutoff").firstMatch.exists)
        XCTAssertTrue(app.staticTexts["保存済みの記録の日付は変更しません。時刻は日本時間です。"].exists)
        proof(app, "late-night-cutoff-setting")
    }
    func testPresetDisplayOrderCanBeFixedAndReturnedToAutomatic() {
        let app = launch(["--p4-preview", "--light"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10))
        tap("並びを固定・変更", app: app); tap("この順で固定", app: app); back(app)
        XCTAssertTrue(app.staticTexts["固定した並びを優先しています"].exists)
        tap("並びを固定・変更", app: app); tap("自動の並びに戻す", app: app); back(app)
        XCTAssertFalse(app.staticTexts["固定した並びを優先しています"].exists)
        XCTAssertTrue(app.staticTexts["175"].exists)
        proof(app, "preset-fixed-order-and-reset")
    }
    func testLargePresetNeedsOneConfirmationBeforeWriting() {
        let app = launch(["--p4-preview", "--light", "--large-preset"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10))
        tap("架空の5倍を追加", app: app)
        XCTAssertTrue(app.alerts["基準量より大きい食事です"].waitForExistence(timeout: 3))
        app.alerts.buttons["記録しない"].tap()
        XCTAssertTrue(app.staticTexts["175"].exists)
        tap("架空の5倍を追加", app: app); app.alerts.buttons["この量で記録"].tap()
        let total = app.staticTexts.matching(identifier: "675").firstMatch
        reveal(total, app: app); XCTAssertTrue(total.exists)
        proof(app, "large-preset-confirmed-once")
    }
    func testPresetSearchUsesReadingAndSavedLocalAlias() {
        let app = launch(["--p4-preview", "--light"])
        let search=app.textFields["food-preset-search"]
        reveal(search, app: app); search.tap(); search.typeText("ぜんりゅう")
        XCTAssertTrue(app.buttons["全粒粉パンを追加"].exists)
        XCTAssertFalse(app.buttons["いつもの朝食を追加"].exists)
        proof(app, "preset-reading-search")
        app.terminate(); app.launch()
        tap("プリセットを編集", app: app); tap("いつもの朝食のプリセットを編集", app: app)
        let alias=app.textFields["検索用の読み・略称"].exists ? app.textFields["検索用の読み・略称"] : app.textViews["検索用の読み・略称"]
        alias.tap(); alias.typeText("あさせっと")
        tap("保存", app: app); tap("閉じる", app: app)
        reveal(search, app: app); search.tap(); search.typeText("あさせ")
        XCTAssertTrue(app.buttons["いつもの朝食を追加"].exists)
        XCTAssertFalse(app.buttons["全粒粉パンを追加"].exists)
        proof(app, "preset-local-alias-search")
    }
    func testMultiplePhotosAndNoteMakeOneMealDraftAndOneRecord() {
        let app = launch(["--p4-preview", "--light", "--no-questions", "--multi-photo-check"])
        XCTAssertTrue(app.staticTexts["175"].waitForExistence(timeout: 10))
        tap("写真・文章から記録", app: app); tap("架空の写真を2枚追加", app: app)
        XCTAssertTrue(app.staticTexts["同じ1食の写真 2枚"].exists)
        let note=app.textFields["food-analysis-note"].exists ? app.textFields["food-analysis-note"] : app.textViews["food-analysis-note"]
        note.tap(); note.typeText(" スープは半分")
        tap("解析する", app: app)
        XCTAssertTrue(app.staticTexts["確認前の推定 · 合計には未反映"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["写真1を外す"].exists)
        proof(app, "multi-photo-one-draft")
        tap("確認して記録", app: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: note)], timeout: 5), .completed)
        let total=app.staticTexts.matching(identifier: "595").firstMatch
        reveal(total, app: app); XCTAssertTrue(total.exists)
        XCTAssertTrue(app.staticTexts["端末保存・送信待ち 1件。要確認の変更は合計に含めていません。"].exists)
        proof(app, "multi-photo-one-saved-record")
    }
    func testMockAlignedHomeFoodHistoryOtherAndDetailNavigation() {
        let app=launch(["--p7-preview", "--light"])
        // 遷移途中の画面を比較画像にしないよう、撮影前にアニメーションの終了を待ちます。
        func mockProof(_ name: String) { Thread.sleep(forTimeInterval:0.75); proof(app,name) }
        XCTAssertTrue(app.buttons["hub-tab-home"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["10月2日（金）"].exists)
        XCTAssertTrue(app.staticTexts["最新体重"].exists)
        mockProof("p86-home")
        let cycle=app.buttons["カレンダーとCycleを見る"]; reveal(cycle,app:app)
        XCTAssertLessThan(cycle.frame.maxY,app.buttons["hub-tab-home"].frame.minY)
        mockProof("p86-home-bottom")
        tap("目標の内訳",app:app); mockProof("p86-goal"); back(app)
        tap("health-weight-link",app:app); mockProof("p86-weight"); back(app)
        tab("食事",app:app); XCTAssertTrue(app.buttons["いつもの朝食を追加"].waitForExistence(timeout:5))
        mockProof("p86-food")
        tap("履歴",app:app)
        // DisclosureGroupのIDが子へ伝播するため、見出しと行のラベルで絞ります。
        let breakfast=app.staticTexts.matching(identifier:"food-history-朝食").matching(NSPredicate(format:"label CONTAINS %@", "全粒粉パン")).firstMatch
        let header=app.buttons.matching(NSPredicate(format:"identifier == %@ AND label BEGINSWITH %@", "food-history-朝食", "朝食")).firstMatch
        XCTAssertTrue(breakfast.waitForExistence(timeout:3)); mockProof("p86-history-before-fold")
        reveal(header,app:app); header.tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:breakfast)],timeout:3),.completed)
        header.tap(); XCTAssertTrue(breakfast.waitForExistence(timeout:3))
        mockProof("p86-history"); back(app)
        tab("その他",app:app); XCTAssertTrue(app.staticTexts["同期済み"].waitForExistence(timeout:5))
        mockProof("p86-other")
        tap("記録と成績",app:app); tap("トレーニング",app:app); mockProof("p86-training")
        tap("種目の成績を見る",app:app); mockProof("p86-grades")
    }

    func testMockFoodSettingsMenuKeepsDateCatalogAndPreferencesReachable() {
        let app=launch(["--p4-preview", "--light"])
        tap("記録する日を選ぶ",app:app); XCTAssertTrue(app.navigationBars["記録する日"].waitForExistence(timeout:5)); tap("完了",app:app)
        tap("プリセットを編集",app:app); XCTAssertTrue(app.buttons["食品を追加"].waitForExistence(timeout:5)); tap("閉じる",app:app)
        tap("並びを固定・変更",app:app); XCTAssertTrue(app.buttons["この順で固定"].waitForExistence(timeout:5)); back(app)
        tap("食事の記録設定",app:app); XCTAssertTrue(app.navigationBars["食事の記録設定"].waitForExistence(timeout:5)); back(app)
        let total=app.staticTexts.matching(identifier:"175").firstMatch; reveal(total,app:app); XCTAssertTrue(total.exists)
        proof(app,"p86-food-menu-and-preserved-total")
    }

    func testWaterAdditionUndoAndDetailKeepFoodTotal() {
        let app=launch(["--p7-preview","--light"])
        tab("食事",app:app);tap("water-add",app:app)
        XCTAssertTrue(app.staticTexts["250"].exists)
        tap("water-undo",app:app)
        let zero=app.staticTexts.matching(identifier:"0").firstMatch
        XCTAssertTrue(zero.waitForExistence(timeout:3))
        tap("記録・設定",app:app)
        XCTAssertTrue(app.textFields["water-step-input"].waitForExistence(timeout:3))
        XCTAssertTrue(app.textFields["water-goal-input"].exists)
        proof(app,"p84-water-settings")
    }
    func testFoodLabelConfirmationCreatesPresetWithoutExternalAnalysis() {
        let app=launch(["--p4-preview","--light"])
        tap("検索と記録の設定",app:app);tap("成分表示から登録",app:app)
        tap("food-label-preview-sample",app:app)
        let name=app.textFields["food-label-name"];reveal(name,app:app);name.tap();name.typeText("架空バー")
        let confirm=app.switches["food-label-reviewed"];reveal(confirm,app:app);confirm.tap()
        tap("food-label-save",app:app)
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.buttons["food-label-save"])],timeout:3),.completed)
        proof(app,"p84-label-registered")
    }
    func testReferenceFoodSourceAndConfirmationAreVisible() {
        let app=launch(["--p4-preview","--light"])
        tap("検索と記録の設定",app:app);tap("食品成分表から登録",app:app)
        let search=app.searchFields.firstMatch;XCTAssertTrue(search.waitForExistence(timeout:3));search.tap();search.typeText("07107")
        tap("reference-food-row-07107",app:app)
        XCTAssertTrue(app.textFields["reference-food-quantity"].waitForExistence(timeout:3))
        proof(app,"p84-reference-food-confirmation")
    }
    func testEnergyReviewShowsMissingEvidenceWithoutChangingTarget() {
        let app=launch(["--p7-preview","--light"])
        tab("その他",app:app);tap("energy-review-link",app:app)
        XCTAssertTrue(app.switches["energy-review-morning-confirmation"].waitForExistence(timeout:3))
        proof(app,"p84-energy-review")
        back(app);tab("ホーム",app:app);XCTAssertTrue(app.staticTexts["/ 2,000 kcal"].exists)
    }

}
