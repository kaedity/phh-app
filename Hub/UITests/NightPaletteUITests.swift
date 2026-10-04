import XCTest
import UIKit

@MainActor final class NightPaletteUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testDarkSurfaces() throws { try check(dark: true, largest: false) }
    func testLargestDarkSurfaces() throws { try check(dark: true, largest: true) }
    func testLightSurfacesRemain() throws { try check(dark: false, largest: false) }
    func testLargestLightSurfacesRemain() throws { try check(dark: false, largest: true) }
    func testTrainingDarkSurfaceAndSelection() throws { try training(dark: true) }
    func testTrainingLightSurfaceAndSelection() throws { try training(dark: false) }
    private func training(dark: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--p3-preview", "--grades", dark ? "--dark" : "--light"]
        app.launch()
        let squat = app.buttons["スクワット"].firstMatch
        XCTAssertTrue(squat.waitForExistence(timeout: 15))
        try pixel(app.screenshot(), app: app, point: CGPoint(x:squat.frame.midX,y:squat.frame.minY+5), expected: dark ? [36,45,52] : [255,255,255])
        attach(app, name: "palette-training-before-\(dark)")
        squat.tap()
        let bench = app.buttons["ベンチプレス"].firstMatch
        try pixel(app.screenshot(), app: app, point: CGPoint(x:bench.frame.midX,y:bench.frame.minY+5), expected: dark ? [36,45,52] : [255,255,255])
        try pixel(app.screenshot(), app: app, point: CGPoint(x:squat.frame.midX,y:squat.frame.minY+5), expected: dark ? [153,209,179] : [33,87,71])
        attach(app, name: "palette-training-selected-\(dark)")
    }
    private func check(dark: Bool, largest: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--p7-preview"] + (largest ? ["--ax5"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["hub-tab-other"].waitForExistence(timeout: 15))
        app.buttons["hub-tab-other"].tap()
        app.buttons[dark ? "ダークモード" : "ライトモード"].tap()
        let title = app.staticTexts["同期済み"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let shot = app.screenshot()
        try pixel(shot, app: app, point: CGPoint(x: 8, y: 300), expected: dark ? [23,30,35] : [247,245,240])
        let cardRGB = try pixel(shot, app: app, point: CGPoint(x: 24, y: title.frame.midY), expected: dark ? [36,45,52] : [255,255,255])
        try pixel(shot, app: app, point: CGPoint(x: 8, y: app.frame.height-12), expected: dark ? [27,35,40] : [255,255,255])
        if dark { try contrast(background: cardRGB) }
        let a = XCTAttachment(screenshot: shot); a.name = "palette-\(dark)-\(largest)"; a.lifetime = .keepAlways; add(a)
        XCTAssertTrue(app.buttons["ライトモード"].exists && app.buttons["ダークモード"].exists)
        app.buttons["hub-tab-home"].tap()
        XCTAssertTrue(app.buttons["hub-tab-food"].isHittable)
        let weight = app.buttons["health-weight-link"]
        for _ in 0..<12 {
            if weight.exists, weight.isHittable, weight.frame.maxY < app.frame.height-100 { break }
            app.swipeUp()
        }
        XCTAssertTrue(weight.isHittable)
        try pixel(app.screenshot(), app: app, point: CGPoint(x:weight.frame.minX+5,y:weight.frame.midY), expected: dark ? [36,45,52] : [255,255,255])
        attach(app, name: "palette-home-\(dark)-\(largest)")
        app.buttons["hub-tab-other"].tap()
        let goal = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "カロリー・PFCの目標設定")).firstMatch
        for _ in 0..<12 {
            if goal.exists, goal.isHittable, goal.frame.maxY < app.frame.height-100 { break }
            app.swipeUp()
        }
        XCTAssertTrue(goal.isHittable); goal.tap()
        let goalTitle = app.staticTexts["1日の目標摂取カロリー"].firstMatch
        XCTAssertTrue(goalTitle.waitForExistence(timeout: 5))
        try pixel(app.screenshot(), app: app, point: CGPoint(x:24,y:goalTitle.frame.midY), expected: dark ? [36,45,52] : [255,255,255])
        attach(app, name: "palette-goal-\(dark)-\(largest)")
        let basis = app.staticTexts["基準"].firstMatch
        for _ in 0..<12 {
            if basis.exists, basis.isHittable, basis.frame.maxY < app.frame.height-100 { break }
            app.swipeUp()
        }
        XCTAssertTrue(basis.isHittable)
        try pixel(app.screenshot(), app: app, point: CGPoint(x:24,y:basis.frame.midY), expected: dark ? [36,45,52] : [255,255,255])
        attach(app, name: "palette-goal-rows-\(dark)-\(largest)")
    }
    private func attach(_ app: XCUIApplication, name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    @discardableResult private func pixel(_ shot: XCUIScreenshot, app: XCUIApplication, point: CGPoint, expected: [Int]) throws -> [Int] {
        let cg = try XCTUnwrap(shot.image.cgImage)
        let crop = try XCTUnwrap(cg.cropping(to: CGRect(x: point.x*CGFloat(cg.width)/app.frame.width, y: point.y*CGFloat(cg.height)/app.frame.height, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0,y: 0,width: 1,height: 1))
        }
        for i in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(rgba[i])-expected[i]), 2, "point=\(point) rgba=\(rgba) expected=\(expected)") }
        return rgba.prefix(3).map(Int.init)
    }
    private func contrast(background: [Int]) throws {
        let bg = background.map { Double($0)/255 }
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0/12.92 : pow(($0+0.055)/1.055,2.4) }
            return linear[0]*0.2126 + linear[1]*0.7152 + linear[2]*0.0722
        }
        for level in [UIAccessibilityContrast.normal, .high] {
            let traits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: .dark), UITraitCollection(accessibilityContrast: level)])
            for (name, color) in [("label",UIColor.label),("secondary",UIColor.secondaryLabel),("mint",UIColor(red:0.60,green:0.82,blue:0.70,alpha:1))] {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
                XCTAssertTrue(color.resolvedColor(with: traits).getRed(&r,green:&g,blue:&b,alpha:&alpha))
                let rgb = [r,g,b].enumerated().map { Double($0.element)*Double(alpha)+bg[$0.offset]*(1-Double(alpha)) }
                let ratio = (max(luminance(rgb),luminance(bg))+0.05)/(min(luminance(rgb),luminance(bg))+0.05)
                print("PHH_CONTRAST \(level.rawValue) \(name) \(ratio)")
                XCTAssertGreaterThanOrEqual(ratio,4.5)
            }
        }
    }
}
