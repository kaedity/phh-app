import SwiftUI
import PHHHubCore

/// 選択の保存はすぐ行い、装飾だけを動かします。
struct MotionSegments<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var marker
    @State private var stretched = false
    @State private var settling: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var textSize
    private var policy = MotionPolicy()
    var body: some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
        layout {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index], selected = selection == option.0
                Button {
                    guard selection != option.0 else { return }
                    settling?.cancel()
                    withAnimation(Motion.animation(reduceMotion: policy.reduced)) { selection = option.0; stretched = !policy.reduced }
                    Haptics.emit(.selection)
                    settling = Task {
                        do { try await Task.sleep(for: .seconds(Motion.duration())); withAnimation(Motion.animation(reduceMotion: policy.reduced)) { stretched = false } }
                        catch {}
                    }
                } label: {
                    Text(option.1).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        .foregroundStyle(.primary)
                        .background {
                            if selected {
                                Capsule().fill(pine.opacity(0.16)).scaleEffect(x: stretched ? Motion.stretch : 1)
                                    .matchedGeometryEffect(id: "selection", in: marker)
                            }
                        }
                }.buttonStyle(HubPressStyle()).accessibilityLabel(option.1)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.padding(4).background(pine.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .contain).accessibilityIdentifier("segments-" + title).onDisappear { settling?.cancel() }
    }
}
struct MotionToggleStyle: ToggleStyle {
    private var policy = MotionPolicy()
    @Environment(\.isEnabled) private var enabled
    @State private var stretched = false
    @State private var settling: Task<Void, Never>?
    func makeBody(configuration: Configuration) -> some View {
        Button {
            guard enabled else { return }; settling?.cancel()
            withAnimation(Motion.animation(reduceMotion: policy.reduced)) { configuration.isOn.toggle(); stretched = !policy.reduced }
            Haptics.emit(.selection)
            settling = Task {
                do { try await Task.sleep(for: .seconds(Motion.duration())); withAnimation(Motion.animation(reduceMotion: policy.reduced)) { stretched = false } }
                catch {}
            }
        } label: {
            HStack {
                configuration.label.foregroundStyle(.primary)
                Spacer()
                Capsule().fill(configuration.isOn ? pine : Color.secondary.opacity(0.3)).frame(width: 54, height: 32)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Color(uiColor: .systemBackground)).frame(width: 26, height: 26)
                            .scaleEffect(x: stretched ? Motion.stretch : 1).padding(3)
                    }
            }.frame(minHeight: 44).contentShape(Rectangle()).opacity(enabled ? 1 : 0.5)
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "オン" : "オフ")
            .accessibilityAddTraits(.isButton).onDisappear { settling?.cancel() }
    }
}
struct MotionDots: View {
    private var policy = MotionPolicy()
    var body: some View {
        TimelineView(.animation(paused: policy.reduced)) { context in
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle().fill(pine).frame(width: 6, height: 6)
                        .offset(y: Motion.dotOffset(time: context.date.timeIntervalSinceReferenceDate, index: index, reduced: policy.reduced))
                }
            }.frame(height: 18)
        }.accessibilityLabel("処理中")
    }
}
struct MotionSyncSymbol: View {
    var busy: Bool
    var succeeded = false
    private var policy = MotionPolicy()
    var body: some View {
        TimelineView(.animation(paused: !busy || policy.reduced)) { context in
            Image(systemName: !busy && succeeded ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(busy && !policy.reduced ? Motion.rotation(time: context.date.timeIntervalSinceReferenceDate) : 0))
        }.accessibilityHidden(true)
    }
}
struct MotionSuccessSeal: View {
    private var policy = MotionPolicy()
    @State private var drawn = false
    @State private var checked = false
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: drawn ? 1 : 0).stroke(pine, style: .init(lineWidth: 2, lineCap: .round))
            Path { path in path.move(to: .init(x: 7, y: 14)); path.addLine(to: .init(x: 12, y: 19)); path.addLine(to: .init(x: 21, y: 9)) }
                .trim(from: 0, to: checked ? 1 : 0).stroke(pine, style: .init(lineWidth: 2, lineCap: .round))
        }.frame(width: 28, height: 28).task(id: policy.reduced) {
            drawn = policy.reduced; checked = policy.reduced
            withAnimation(Motion.gentle(reduceMotion: policy.reduced)) { drawn = true }
            if !policy.reduced { do { try await Task.sleep(for: .seconds(Motion.duration())) } catch { return } }
            withAnimation(Motion.gentle(reduceMotion: policy.reduced)) { checked = true }
        }
            .accessibilityLabel("完了")
    }
}
struct MotionReveal: ViewModifier {
    var order: Int = 0
    private var policy = MotionPolicy()
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown || policy.reduced ? 0 : Motion.revealDistance)
            .onAppear { withAnimation(Motion.revealAnimation(reduceMotion: policy.reduced, order: order)) { shown = true } }
    }
}
struct MotionChartReveal: ViewModifier {
    let key: String
    private var policy = MotionPolicy()
    @State private var shown = false
    func body(content: Content) -> some View {
        content.mask(Rectangle().scaleEffect(x: shown ? 1 : 0, anchor: .leading))
            .task(id: key + String(policy.reduced)) {
                shown = policy.reduced
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(Motion.gentle(reduceMotion: policy.reduced)) { shown = true }
            }
    }
}
struct MotionFieldError: ViewModifier {
    let error: String
    private var policy = MotionPolicy()
    @State private var shifted = false
    @State private var reset: Task<Void, Never>?
    func body(content: Content) -> some View {
        content.offset(x: shifted && !policy.reduced ? Motion.errorDistance : 0)
            .onChange(of: error) { _, value in
                reset?.cancel(); shifted = false
                guard !value.isEmpty else { return }; Haptics.emit(.warning)
                withAnimation(Motion.errorAnimation(reduceMotion: policy.reduced)) { shifted = true }
                reset = Task { do { try await Task.sleep(for: .seconds(Motion.duration())); shifted = false } catch {} }
            }.onDisappear { reset?.cancel() }
    }
}
struct MotionInfo: View {
    let text: String
    @State private var open = false
    var body: some View {
        Button { open = true } label: { Image(systemName: "questionmark.circle").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("説明：" + text).popover(isPresented: $open) {
                Text(text).font(.body).padding(20).presentationCompactAdaptation(.popover)
            }
    }
}
extension View {
    func motionReveal(order: Int = 0) -> some View { modifier(MotionReveal(order: order)) }
    func motionFieldError(_ error: String) -> some View { modifier(MotionFieldError(error: error)) }
    @ViewBuilder func motionZoom(id: String, in namespace: Namespace.ID, reduced: Bool) -> some View {
        if reduced { self } else { self.navigationTransition(.zoom(sourceID: id, in: namespace)) }
    }
}

struct MotionRadioChoice<Value: Hashable>: View {
    let title: String
    let value: Value
    @Binding var selection: Value
    private var policy = MotionPolicy()
    var body: some View {
        Button { selection = value; Haptics.emit(.selection) } label: {
            HStack { Text(title); Spacer(); ZStack {
                Circle().stroke(pine, lineWidth: 2).frame(width: 22, height: 22)
                Circle().fill(pine).frame(width: 12, height: 12).scaleEffect(selection == value ? 1 : 0)
                    .animation(Motion.animation(reduceMotion: policy.reduced), value: selection)
            } }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}
struct MotionSaveLabel: View {
    let title: String
    var busy = false
    var saved = false
    private var policy = MotionPolicy()
    var body: some View {
        HStack { if busy { MotionDots() }; if saved { Image(systemName: "checkmark") }; Text(busy ? "保存中…" : saved ? "保存しました" : title) }
            .frame(minHeight: 44).padding(.horizontal, 8)
            .background { RoundedRectangle(cornerRadius: 10).fill(pine.opacity(0.14)).scaleEffect(x: saved ? 1 : 0, anchor: .leading) }
            .animation(Motion.animation(reduceMotion: policy.reduced), value: saved)
            .contentTransition(.opacity)
    }
}
struct MotionRowMenu<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open = false
    @Namespace private var shape
    private var policy = MotionPolicy()
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button { withAnimation(Motion.animation(reduceMotion: policy.reduced)) { open.toggle() }; Haptics.emit(.lightPress) } label: {
                Image(systemName: open ? "xmark" : "ellipsis").frame(width: 44, height: 44)
                    .background { Circle().fill(pine.opacity(0.08)).matchedGeometryEffect(id: "menu", in: shape, isSource: !open) }
            }.buttonStyle(.plain).accessibilityLabel(open ? "メニューを閉じる" : title + "のメニュー")
            if open {
                VStack(alignment: .leading, spacing: 12) { content }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 18).fill(pine.opacity(0.08)).matchedGeometryEffect(id: "menu", in: shape, isSource: true) }
                    .transition(.opacity)
            }
        }
    }
}
struct MotionIntakeRing: View {
    let fraction: Double?
    private var policy = MotionPolicy()
    var body: some View {
        ZStack {
            Circle().stroke(pine.opacity(0.14), lineWidth: 13)
            if let fraction {
                Circle().trim(from: 0, to: max(0, min(1, fraction))).stroke(pine, style: .init(lineWidth: 13, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(Motion.animation(reduceMotion: policy.reduced), value: fraction)
                if fraction >= 1 { Image(systemName: "checkmark.seal.fill").foregroundStyle(pine).offset(x: 84, y: -84).transition(.scale) }
            }
        }.animation(Motion.animation(reduceMotion: policy.reduced), value: (fraction ?? 0) >= 1)
            .onChange(of: (fraction ?? 0) >= 1) { _, done in if done { Haptics.emit(.success) } }
            .accessibilityHidden(true)
    }
}
struct MotionSkeleton: View {
    private var policy = MotionPolicy()
    var body: some View {
        TimelineView(.animation(paused: policy.reduced)) { context in
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 6).frame(width: proxy.size.width * 0.6, height: 12)
                    RoundedRectangle(cornerRadius: 6).frame(height: 12)
                }.foregroundStyle(pine.opacity(0.1)).overlay {
                    if !policy.reduced {
                        Rectangle().fill(.white.opacity(0.12)).frame(width: proxy.size.width * 0.25)
                            .offset(x: Motion.sweep(time: context.date.timeIntervalSinceReferenceDate) * proxy.size.width)
                    }
                }.clipped()
            }.frame(height: 34)
        }.accessibilityElement(children: .ignore).accessibilityLabel("履歴を読み込み中。前回の値を表示しています。")
    }
}

struct MotionCycleGrid: View {
    let slots: [TrainingPlanSlot]
    let completed: Set<String>
    @Environment(\.dynamicTypeSize) private var textSize
    private var policy = MotionPolicy()
    @State private var pulse = false
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: textSize.isAccessibilitySize ? 2 : 3), spacing: 10) {
            ForEach(slots) { slot in MotionCycleTile(slot: slot, done: completed.contains(slot.id)) }
        }.scaleEffect(pulse && !policy.reduced ? Motion.cyclePulse : 1)
            .task(id: completed.count) {
                guard completed.count == 9 else { pulse=false; return }
                withAnimation(Motion.animation(reduceMotion: policy.reduced)) { pulse=true }
                do { try await Task.sleep(for: .seconds(Motion.duration())) } catch { return }
                withAnimation(Motion.animation(reduceMotion: policy.reduced)) { pulse=false }
            }.onChange(of: completed.count) { _, value in if value == 9 { Haptics.emit(.success) } }
            .accessibilityElement(children: .contain).accessibilityIdentifier("motion-cycle")
    }
}

#if DEBUG
/// 本番と同じ部品を操作する、通信/端末保存のない入口です。
struct MotionPatternsPreviewRoot: View {
    private var policy = MotionPolicy()
    @State private var tab = "食事"
    @State private var option = "維持"
    @State private var enabled = false
    @State private var busy = false
    @State private var saved = false
    @State private var count = 0
    @State private var fraction = 0.0
    @State private var cycleDone: Set<String> = []
    @State private var error = ""
    @State private var number = ""
    var body: some View {
        NavigationStack { Page(title: "動きの操作確認（合成）") {
            Text(policy.reduced ? "装飾：停止" : "装飾：動作").accessibilityIdentifier("patterns-policy")
            MotionSegments(title: "ページ", selection: $tab, options: [("食事","食事"),("設定","設定"),("進捗","進捗")])
            Text("選択：" + tab).accessibilityIdentifier("patterns-tab")
            if tab == "食事" {
                Button {
                    guard !busy else { return }; busy=true; saved=false
                    Task {
                        do { try await Task.sleep(for: .seconds(Motion.duration() * 5)) } catch { return }
                        count += 1; busy=false; saved=true
                    }
                } label: { MotionSaveLabel(title: "保存", busy: busy, saved: saved) }.disabled(busy).accessibilityLabel("保存動作")
                Text("保存 \(count)件").accessibilityIdentifier("patterns-count")
                HStack { MotionSyncSymbol(busy: busy, succeeded: saved); Text(busy ? "同期中" : saved ? "同期完了" : "未同期") }
                MotionRowMenu(title: "見本") { Button("編集の見本") { error="入力する数値を確認してください。" } }
                TextField("数値", text: $number).textFieldStyle(.roundedBorder).motionFieldError(error)
                if !error.isEmpty { Text(error).accessibilityIdentifier("patterns-error") }
                MotionInfo(text: "推定値は確認するまで記録に含みません。")
                MotionSkeleton()
            } else if tab == "設定" {
                Toggle("自動補正", isOn: $enabled)
                MotionRadioChoice(title: "維持", value: "維持", selection: $option)
                MotionRadioChoice(title: "増量", value: "増量", selection: $option)
                Text("選択：" + option).accessibilityIdentifier("patterns-option")
            } else {
                MotionIntakeRing(fraction: fraction).frame(width: 180, height: 180)
                Button("リングを満たす") { fraction=1 }
                if fraction == 1 { MotionSuccessSeal(); Text("記録完了") }
                Button("Cycleの9枠を完了") { cycleDone=Set(TrainingPreviewData.cycle.slots.map(\.id)) }
                MotionCycleGrid(slots: TrainingPreviewData.cycle.slots, completed: cycleDone)
                Text("Cycle \(cycleDone.count) / 9").accessibilityIdentifier("patterns-cycle-count")
            }
        } }.tint(pine)
    }
}
#endif
private struct MotionCycleTile: View {
    let slot: TrainingPlanSlot
    let done: Bool
    private var policy = MotionPolicy()
    @State private var bounced = false
    var body: some View {
        VStack(spacing: 5) { Text(String(slot.number)).font(.headline); Text(slot.label).font(.caption); if done { Image(systemName: "checkmark") } }
            .frame(maxWidth: .infinity, minHeight: 66).padding(8)
            .background(done ? slot.kind.color.opacity(0.25) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(bounced && !policy.reduced ? Motion.stretch : 1)
            .task(id: done) {
                guard done else { bounced=false; return }
                withAnimation(Motion.animation(reduceMotion: policy.reduced)) { bounced=true }
                do { try await Task.sleep(for: .seconds(Motion.duration())) } catch { return }
                withAnimation(Motion.animation(reduceMotion: policy.reduced)) { bounced=false }
            }.accessibilityElement(children: .ignore).accessibilityLabel("\(slot.number)・\(slot.label)・\(done ? "完了" : "未完了")")
    }
}
