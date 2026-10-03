import SwiftUI
import UIKit

// 動きの速さ・弾みはここだけで決めます。保存/同期の完了を遅延させません。
enum Motion {
    enum Firmness { case soft, normal, firm }
    static let adopted: Firmness = .normal
    static let pressedScale: CGFloat = 0.98
    static let rowDelay = 0.045

    static let stretch: CGFloat = 1.16
    static let cyclePulse: CGFloat = 1.025
    static let revealDistance: CGFloat = 8
    static let errorDistance: CGFloat = 6
    static func loop(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .linear(duration: duration() * 4).repeatForever(autoreverses: false)
    }
    static func revealAnimation(reduceMotion: Bool, order: Int) -> Animation? {
        animation(reduceMotion: reduceMotion)?.delay(Double(min(order, 8)) * rowDelay)
    }
    static func errorAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .linear(duration: duration() / 6).repeatCount(6, autoreverses: true)
    }
    static func dotOffset(time: Double, index: Int, reduced: Bool) -> CGFloat {
        reduced ? 0 : -max(0, sin(time / duration() * .pi * 2 - Double(index) * .pi / 2)) * revealDistance
    }
    static func rotation(time: Double) -> Double { time.truncatingRemainder(dividingBy: duration() * 4) / (duration() * 4) * 360 }
    static func sweep(time: Double) -> CGFloat { CGFloat(time.truncatingRemainder(dividingBy: duration() * 4) / (duration() * 4) * 2 - 1) }
    static func duration(_ firmness: Firmness = adopted) -> Double {
        switch firmness { case .soft: 0.48; case .normal: 0.38; case .firm: 0.28 }
    }
    static func animation(reduceMotion: Bool, firmness: Firmness = adopted) -> Animation? {
        guard !reduceMotion else { return nil }
        let damping: Double = switch firmness { case .soft: 0.66; case .normal: 0.72; case .firm: 0.85 }
        return .spring(response: duration(firmness), dampingFraction: damping)
    }
    static func gentle(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration())
    }
    static func pressScale(isPressed: Bool, enabled: Bool, reduceMotion: Bool) -> CGFloat {
        isPressed && enabled && !reduceMotion ? pressedScale : 1
    }
}

// OSの設定は読取専用です。Debugの合成入口だけ、停止状態を重ねて確認できます。
private struct MotionReductionOverrideKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var motionReductionOverride: Bool {
        get { self[MotionReductionOverrideKey.self] }
        set { self[MotionReductionOverrideKey.self] = newValue }
    }
}
struct MotionPolicy: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduction
    @Environment(\.motionReductionOverride) private var previewReduction
    var reduced: Bool { systemReduction || previewReduction }
}

@MainActor enum Haptics {
    enum Event { case success, warning, selection, lightPress }
    static func emit(_ event: Event) {
        switch event {
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .lightPress: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

struct HubPressStyle: ButtonStyle {
    private var motionPolicy = MotionPolicy()
    private var reduceMotion: Bool { motionPolicy.reduced }
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.primary)
            .opacity(configuration.isPressed && enabled ? 0.65 : 1)
            .scaleEffect(Motion.pressScale(isPressed: configuration.isPressed, enabled: enabled, reduceMotion: reduceMotion))
            .animation(Motion.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

#if DEBUG
struct MotionPreviewRoot: View {
    private var motionPolicy = MotionPolicy()
    private var reduceMotion: Bool { motionPolicy.reduced }
    @State private var pressed = false
    @State private var count = 0
    var body: some View {
        NavigationStack {
            Page(title: "動きの確認（合成）") {
                Text(reduceMotion ? "動きを減らす：オン" : "動きを減らす：オフ")
                    .accessibilityIdentifier("motion-policy")
                Button("押下状態を切り替える") { pressed.toggle() }
                Text("押した状態の見本")
                    .padding(24).background(pine.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                    .scaleEffect(Motion.pressScale(isPressed: pressed, enabled: true, reduceMotion: reduceMotion))
                    .animation(Motion.animation(reduceMotion: reduceMotion), value: pressed)
                    .accessibilityValue(pressed && !reduceMotion ? "縮小" : "等倍")
                    .accessibilityIdentifier("motion-sample")
                Button("記録する（合成）") { count += 1; Haptics.emit(.lightPress) }
                    .buttonStyle(HubPressStyle())
                Text("記録 \(count)件").accessibilityIdentifier("motion-count")
                Text("通信・端末保存は行いません。")
            }
        }.tint(pine)
    }
}
#endif
