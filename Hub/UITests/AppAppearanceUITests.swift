import XCTest
import UIKit

@MainActor final class AppAppearanceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testSwitchPersistAndSheet() throws { try check(largest: false) }
    func testLargestSwitchPersistAndSheet() throws { try check(largest: true) }
    func testInitialDarkWithoutSavedSelection() throws { try initial(arguments: ["--appearance-unset"]) }
    func testInvalidSavedSelectionFallsBackToDark() throws { try initial(arguments: ["--appearance-invalid"]) }
    func testDebugOverridesPreserveSavedSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--p7-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["hub-tab-other"].waitForExistence(timeout: 15))
        app.buttons["hub-tab-other"].tap()
        app.buttons["ライトモード"].tap()
        try assertAppearance(app, dark: false, name: "saved-light")
        app.terminate(); app.launchArguments = ["--p7-preview", "--dark"]; app.launch()
        try assertAppearance(app, dark: true, name: "debug-dark")
        app.terminate(); app.launchArguments = ["--p7-preview"]; app.launch()
        try assertAppearance(app, dark: false, name: "saved-light-after-override")
        app.buttons["hub-tab-other"].tap()
        app.buttons["ダークモード"].tap()
        app.terminate(); app.launchArguments = ["--p7-preview", "--light"]; app.launch()
        try assertAppearance(app, dark: false, name: "debug-light")
        app.terminate(); app.launchArguments = ["--p7-preview"]; app.launch()
        try assertAppearance(app, dark: true, name: "saved-dark-after-override")
    }
    private func initial(arguments: [String]) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--p7-preview"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["hub-tab-other"].waitForExistence(timeout: 15))
        try assertAppearance(app, dark: true, name: arguments[0])
        app.buttons["hub-tab-other"].tap()
        XCTAssertTrue(app.buttons["ダークモード"].isSelected)
    }
    private func check(largest: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--p7-preview"] + (largest ? ["--ax5"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["hub-tab-other"].waitForExistence(timeout: 15))
        app.buttons["hub-tab-other"].tap()
        let light = app.buttons["ライトモード"], dark = app.buttons["ダークモード"]
        XCTAssertTrue(light.waitForExistence(timeout: 5), "その他に外観切替が必要")
        light.tap(); try assertAppearance(app, dark: false, name: "light-\(largest)")
        dark.tap(); try assertAppearance(app, dark: true, name: "dark-\(largest)")
        app.terminate(); app.launch()
        try assertAppearance(app, dark: true, name: "dark-relaunch-\(largest)")
        try sheet(app, dark: true, largest: largest)
        app.buttons["hub-tab-other"].tap()
        light.tap(); try assertAppearance(app, dark: false, name: "light-return-\(largest)")
        app.terminate(); app.launch()
        try assertAppearance(app, dark: false, name: "light-relaunch-\(largest)")
        try sheet(app, dark: false, largest: largest)
    }
    private func sheet(_ app: XCUIApplication, dark: Bool, largest: Bool) throws {
        app.buttons["hub-tab-food"].tap()
        let menu = app.buttons["検索と記録の設定"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        app.buttons["記録する日を選ぶ"].tap()
        XCTAssertTrue(app.buttons["完了"].waitForExistence(timeout: 5))
        try assertAppearance(app, dark: dark, name: "sheet-\(dark)-\(largest)", sheet: true)
        app.buttons["完了"].tap()
    }
    private func assertAppearance(_ app: XCUIApplication, dark: Bool, name: String, sheet: Bool = false) throws {
        // rootはタブのsafe area、標準glass sheetは文字のないヘッダー位置。本文の透過色や日付の選択値を避ける。
        let darkLimit = sheet ? 0.3 : 0.2
        var brightness: Double = 0
        for attempt in 0..<12 {
            let shot = app.screenshot()
            let cg = try XCTUnwrap(shot.image.cgImage)
            let sample: CGPoint
            if sheet {
                let bar = app.navigationBars.firstMatch.frame
                sample = CGPoint(x: bar.minX + 24, y: bar.minY + 8)
                if attempt == 0 { print("PHH_SHEET_SAMPLE \(name) bar=\(bar) point=\(sample)") }
            } else { sample = CGPoint(x: 8, y: app.frame.height - 12) }
            let point = CGPoint(x: sample.x * CGFloat(cg.width) / app.frame.width, y: sample.y * CGFloat(cg.height) / app.frame.height)
            let crop = try XCTUnwrap(cg.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            brightness = Double(Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / (3 * 255)
            if dark ? brightness < darkLimit : brightness > 0.85 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(dark ? brightness < darkLimit : brightness > 0.85, "\(name): brightness=\(brightness)")
    }
}
