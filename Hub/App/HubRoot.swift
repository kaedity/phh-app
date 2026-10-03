import SwiftUI
import UIKit
import PHHHubCore

let pine = Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(red: 0.60, green: 0.82, blue: 0.70, alpha: 1) : UIColor(red: 0.13, green: 0.34, blue: 0.28, alpha: 1) })
let canvas = Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? .systemGroupedBackground : UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1) })

struct HubRoot: View {
    let model: HubModel
    @Environment(\.scenePhase) private var phase
    @State private var selectedTab = HubRoot.initialTab
    @State private var otherNavigationID = 0
    // 確認用：合成表示で `--tab food` / `--tab other` を付けると、そのタブから始める。
    private static var initialTab: String {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, ["home","food","other"].contains(args[i+1]) { return args[i+1] }
        #endif
        return "home"
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomePage(model: model) }.toolbar(.hidden,for:.tabBar).tabItem { Label("ホーム", systemImage: "house.fill") }.tag("home")
            NavigationStack {
                if model.foodWriteEnabled,let food=model.foodScreen { FoodHubPage(model:food,date:FoodDates.date(model.date),analyze:model.realFoodEnabled ? {try await model.chatGPT.analyzeFood(jpegs:$0,note:$1)}:nil,preview:false,planning:model.planningScreen,syncing:model.busy,implicitDate:!model.previewOnly,hydration:model.hydrationScreen,plateAnalyze:model.realFoodEnabled ? {try await model.chatGPT.analyzeSharedPlate(before:$0,after:$1,note:$2)}:nil) }
                else { FoodPage(model:model) }
            }.toolbar(.hidden,for:.tabBar).tabItem { Label("食事", systemImage: "fork.knife") }.tag("food")
            NavigationStack { OtherPage(model: model) }.id(otherNavigationID).toolbar(.hidden,for:.tabBar).tabItem { Label("その他", systemImage: "ellipsis") }.tag("other")
        }
        // 内側のNavigationStackの戻すバーも、外側の固定タブを避けます。
        .environment(\.foodUndoBottomInset, HubMockTabBar.reservedHeight + 8)
        .tint(pine)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HubMockTabBar(selection: $selectedTab, onReselect: { key in
                if key == "other" { otherNavigationID += 1 }
            })
        }
        .task { await model.start() }
        .onChange(of: phase) { _, value in
            if value == .active { Task { await model.catchUpHealth(); if model.google.connected { await model.synchronize() } } }
        }
    }
}

struct Page<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) { content }.padding(20).padding(.bottom, 16) }
            // モック準拠：大きいタイトルを使わず、上部中央の小さいタイトルにそろえる（DESIGN 2.6）。
            .background(canvas).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 14) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(pine.opacity(0.05))) }
}
struct AccessibleRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var textSize
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing)) : AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        layout { content }
    }
}
private struct Action: View {
    let title: String
    let symbol: String
    var disabled = false
    let run: () async -> Void
    var body: some View {
        Button { Haptics.emit(.lightPress); Task { await run() } } label: {
            Label(title, systemImage: symbol).font(.headline).frame(maxWidth: .infinity, minHeight: 36)
        }.buttonStyle(.borderedProminent).tint(Color(red: 0.13, green: 0.34, blue: 0.28)).foregroundStyle(.white).disabled(disabled)
    }
}
private struct SyncCard: View {
    let model: HubModel
    private var hasIssue: Bool { model.message.contains("失敗") || model.message.contains("確認できません") || model.message.contains("必要") || model.pending.contains { $0.state == .conflict || $0.state == .invalid || $0.state == .authentication } }
    var compact = false
    var body: some View {
        if compact {
            HubMockCard {
                HStack(spacing:12) {
                    Image(systemName:hasIssue ? "exclamationmark.circle.fill" : model.lastSynchronizedAt != nil ? "checkmark.circle.fill" : "clock.circle").font(.system(size:38)).foregroundStyle(hasIssue ? Color.orange : pine)
                    VStack(alignment:.leading,spacing:5) {
                        Text(model.busy ? "同期しています" : hasIssue ? "同期を確認してください" : model.lastSynchronizedAt != nil ? "同期済み" : "同期状態").font(.headline)
                        Text("最終 " + (model.lastSynchronizedAt.map { let f=DateFormatter(); f.dateFormat="H:mm"; f.timeZone=FoodDates.calendar.timeZone; return f.string(from:$0) } ?? "—") + " · 送信待ち \(model.pending.count)件").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(); if model.busy { MotionDots() }
                }
                if hasIssue { Text(model.message).font(.caption).foregroundStyle(.orange) }
            }
        } else {
        Card {
            HStack { MotionSyncSymbol(busy: model.busy, succeeded: model.message.hasPrefix("同期しました")); Text(model.busy ? "同期しています" : hasIssue ? "同期を確認してください" : model.lastSynchronizedAt != nil ? "同期済み" : "同期状態"); Spacer(); if model.busy { MotionDots() } }
            Text("最終：" + (model.lastSynchronizedAt.map(mockDayTime) ?? "—")).font(.caption).foregroundStyle(.secondary)
            Text(model.message).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("sync-message")
            if !model.pending.isEmpty { Label("送信待ち \(model.pending.count)件", systemImage: "tray").font(.subheadline) }
            Action(title: model.busy ? "確認しています…" : "今すぐ同期", symbol: "arrow.clockwise", disabled: model.busy || !model.google.connected) { await model.synchronize(forceQueued: true) }
        }
        }
    }
}
private func number(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—" }

private struct HomePage: View {
    let model: HubModel
    @Namespace private var cardZoom
    private var motion = MotionPolicy()
    @Environment(\.dynamicTypeSize) private var textSize
    private var food: FoodDayPresentation? {
        guard model.foodWriteEnabled, let screen = model.foodScreen else { return nil }
        return try? .init(date: model.date, snapshot: screen.state)
    }
    private var goal: DailyGoal? {
        guard let planning = model.planningScreen else { return nil }
        return try? planning.goal(model.date)
    }
    private func amount(_ nutrient: FoodNutrient, field: String, total: FoodTotal?) -> Double? {
        if let total { return total.displayValue(for:nutrient) }
        return model.summary?.values[field]?.number
    }
    var body: some View {
        HubMockPage {
            let food = self.food
            let total = food.map { projection in (try? model.planningScreen?.totalWithSupplements(projection.localTotal, date: model.date)) ?? projection.localTotal }
            let goal = self.goal
            let kcal = amount(.kcal, field: "kcal", total: total)
            let unknown = total?.missing.values.contains { $0 > 0 } ?? model.summary.map { summary in ["kcal_unknown", "protein_unknown", "fat_unknown", "carbohydrate_unknown"].contains { (summary.values[$0]?.number ?? 0) > 0 } } ?? false
            HStack {
                VStack(alignment:.leading,spacing:4) { Text(mockDay(model.date)).font(.headline); Text("今日も、いいバランスで").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName:"leaf.fill").font(.title).foregroundStyle(pine.opacity(0.22))
            }
            ZStack {
                if !textSize.isAccessibilitySize { MotionIntakeRing(fraction: goal?.total.kcal.flatMap { target in target > 0 ? kcal.map { $0/target } : nil }).frame(width:224,height:224) }
                VStack(spacing:8) {
                    Text("摂取").font(.subheadline)
                    MockFigure(value:number(kcal),unit:"kcal",size:40)
                    Text(goal.map { "/ \(number($0.total.kcal)) kcal" } ?? "目標未設定").font(.caption).foregroundStyle(.secondary)
                    if let target=goal?.total.kcal, let kcal {
                        Divider().frame(width:130)
                        Text(kcal <= target ? "残り \(number(target-kcal)) kcal" : "目標より＋\(number(kcal-target)) kcal").font(.caption)
                    }
                }
            }.frame(maxWidth:.infinity).padding(.vertical,4)
            AccessibleRow(spacing:12) {
                HubMacroProgress(title:"たんぱく質",symbol:"P",value:amount(.protein,field:"protein_g",total:total),target:goal?.total.protein,color:pfcProtein)
                HubMacroProgress(title:"脂質",symbol:"F",value:amount(.fat,field:"fat_g",total:total),target:goal?.total.fat,color:pfcFat)
                HubMacroProgress(title:"炭水化物",symbol:"C",value:amount(.carbohydrate,field:"carbohydrate_g",total:total),target:goal?.total.carbohydrate,color:pfcCarb)
            }
            if unknown { HubUnknownNutrientsHelp() }
            if let planning=model.planningScreen {
                NavigationLink { GoalDetailPage(model:planning,date:model.date,consumed:total.map { planningConsumed(total:$0) } ?? planningConsumed(summary:model.summary)).toolbar(.visible,for:.navigationBar) } label: { HubSettingsRow(title:"目標の内訳",subtitle:"",symbol:"scope").padding(9).background(.background,in:RoundedRectangle(cornerRadius:14)) }.buttonStyle(.plain).accessibilityLabel("目標の内訳")
            }
            if let health=model.healthScreen { HubHealthTiles(model:model,screen:health) }
            NavigationLink { TrainingCalendarPage(snapshot:model.trainingSnapshot,status:model.message,reference:model.trainingCycles.first,date:FoodDates.date(model.date),cycles:model.trainingCycles,saveReference:model.trainingWriteEnabled ? { await model.registerTrainingCycle($0) }:nil,updateSession:model.trainingWriteEnabled ? { await model.updateTrainingSession($0,state:$1,cycle:$2,slot:$3) }:nil).toolbar(.visible,for:.navigationBar) } label: {
                HubMockCard { HubSettingsRow(title:cycleTitle,subtitle:elapsedTraining,symbol:"dumbbell.fill") }
            }.buttonStyle(.plain).accessibilityLabel("カレンダーとCycleを見る")
            if !model.busy && !model.message.hasPrefix("同期しました") && (model.message.contains("失敗") || model.message.contains("必要") || model.message.contains("確認できません")) { Text(model.message).font(.caption).foregroundStyle(.orange) }
        }
    }
    private var cycleTitle: String {
        guard let cycle=model.trainingCycles.first else { return "トレーニング" }
        return "\(cycle.name) · \(cycle.completedSlots(in:model.trainingSnapshot).count) / \(cycle.slots.count)"
    }
    private var elapsedTraining: String { TrainingElapsed.summary(model.trainingSnapshot, today: model.date, now: Date()) }
}
private struct Macro: View {
    let title: String; let symbol: String; let value: Double?
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text("\(symbol) \(number(value))g").font(.headline) }.frame(maxWidth: .infinity) }
}
private struct FoodPage: View {
    let model: HubModel
    var body: some View {
        Page(title: "食事") {
            Text("\(mockDay(model.date)) · 準備用の架空データ").font(.subheadline).foregroundStyle(.secondary)
            #if DEBUG
            Card {
                Label("記録テスト", systemImage: "plus.circle").font(.headline)
                Text("1個 · 100 kcal\nP 10g / F 0g / C 15g").font(.subheadline).foregroundStyle(.secondary)
                Action(title: model.busy ? "保存しています…" : "100 kcalを記録", symbol: "plus", disabled: model.busy) { await model.makeMeal() }
            }
            #else
            Card { Text("食事の接続を準備しています。").foregroundStyle(.secondary) }
            #endif
            Text("確定した食事").font(.headline)
            if model.meals.isEmpty { Card { Text("まだ記録がありません").foregroundStyle(.secondary) } }
            ForEach(model.meals) { meal in
                Card {
                    HStack(alignment: .firstTextBaseline) { Text(meal.values["slot"]?.text ?? "食事").font(.caption).foregroundStyle(pine); Spacer(); Text("保存済み").font(.caption).foregroundStyle(.secondary) }
                    Text(meal.values["name"]?.text ?? "記録テスト").font(.title3.bold())
                    Text("\(number(model.kcal(meal))) kcal").font(.title2.weight(.semibold))
                    #if DEBUG
                    HStack {
                        Button("1個に変更") { feedback(); Task { await model.changeMeal(meal, quantity: 1) } }
                        Button("2個に変更") { feedback(); Task { await model.changeMeal(meal, quantity: 2) } }
                        Spacer()
                        Button("取消", role: .destructive) { feedback(); Task { await model.removeMeal(meal) } }
                    }.buttonStyle(.bordered).disabled(model.busy || model.pending.contains(where: { $0.operation.entity_id == meal.entityID }))
                    #endif
                }
            }
            SyncCard(model: model)
        }
    }
    private func feedback() { Haptics.emit(.lightPress) }
}
private struct OtherPage: View {
    let model: HubModel
    var body: some View {
        HubMockPage {
            SyncCard(model:model,compact:true)
            otherSection("設定") {
                if let planning=model.planningScreen {
                    NavigationLink { GoalDetailPage(model:planning,date:model.date,consumed:planningConsumed(summary:model.summary)).toolbar(.visible,for:.navigationBar) } label: { otherRow("目標","カロリー・PFCの目標設定","scope") }
                }
                if let food=model.foodScreen {
                    NavigationLink { FoodCatalogPage(model:food).toolbar(.visible,for:.navigationBar) } label: { otherRow("カテゴリー","食事の分類・プリセット・読みの設定","square.grid.2x2") }
                }
                NavigationLink { RecordingPreferencesPage().toolbar(.visible,for:.navigationBar) } label: { otherRow("食事の記録設定","日付の区切り・前回値・確認の基準","clock") }
                NavigationLink { Page(title:"連携") { connections }.navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar) } label: { otherRow("連携","ヘルスケア・外部アプリ","link") }
                NavigationLink { Page(title:"同期") { SyncCard(model:model); syncDetails }.navigationBarTitleDisplayMode(.inline).toolbar(.visible,for:.navigationBar) } label: { otherRow("同期","送信待ち・再接続・同期の設定","arrow.triangle.2.circlepath",last:true) }
            }
            otherSection("見直し") {
                if let hub=model.store,let planning=model.planningScreen,let health=model.healthScreen {
                    NavigationLink {EnergyReviewPage(hub:hub,planning:planning,health:health,date:model.date)} label: {otherRow("カロリーの見直し","体重と摂取量から週1回確認","chart.line.uptrend.xyaxis")}.accessibilityIdentifier("energy-review-link")
                }
                if let hub=model.store,let planning=model.planningScreen {
                    NavigationLink {WeeklyAllocationPage(hub:hub,planning:planning,date:model.date,preview:model.previewOnly)} label: {otherRow("週内の配分","食べ過ぎた分を残りの日で調整（試算）","calendar.badge.clock")}.accessibilityIdentifier("weekly-allocation-link")
                }
                if let hub=model.store {NavigationLink {TrainingInsightsPage(hub:hub,date:model.date)} label: {otherRow("トレーニングの見直し","停滞と負荷を落とす週の目安","figure.strengthtraining.traditional")}}
                if let hub=model.store {NavigationLink {SleepTrainingInsightsPage(hub:hub,date:model.date,autoSleep:model.autoSleepDeliveries)} label: {otherRow("睡眠と成績","前夜の睡眠とその日の成績を比べる","moon.zzz")}.accessibilityIdentifier("sleep-training-link")}
                NavigationLink {MuscleRecoveryPage(snapshot:model.trainingSnapshot,asOf:Date())} label: {otherRow("部位と前回の実施","部位の対応を編集・経過時間を確認","figure.cooldown",last:true)}.accessibilityIdentifier("muscle-recovery-link")
            }
            DisclosureGroup("記録と成績") {
                VStack(spacing:0) {
                    if let health=model.healthScreen { NavigationLink { HealthDetailPage(screen:health,autoSleep:model.autoSleepDeliveries,readEnabled:model.healthReadEnabled,readPrepared:model.healthReadPrepared,connect:{await model.connectHealth()},refresh:{await model.catchUpHealth()}) } label: { otherRow("健康データと体重","体重・睡眠・歩数・活動の記録","heart.text.clipboard") } }
                    NavigationLink { TrainingCalendarPage(snapshot:model.trainingSnapshot,status:model.message,reference:model.trainingCycles.first,date:FoodDates.date(model.date),cycles:model.trainingCycles,saveReference:model.trainingWriteEnabled ? { await model.registerTrainingCycle($0) }:nil,updateSession:model.trainingWriteEnabled ? { await model.updateTrainingSession($0,state:$1,cycle:$2,slot:$3) }:nil).toolbar(.visible,for:.navigationBar) } label: { otherRow("トレーニング","カレンダーとCycle","calendar") }
                    NavigationLink { TrainingGradesPage(snapshot:model.trainingSnapshot,date:FoodDates.date(model.date)).toolbar(.visible,for:.navigationBar) } label: { otherRow("種目の成績","推定1RM・自己ベスト","chart.xyaxis.line",last:true) }
                }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)).padding(.top,8)
            }.font(.subheadline.bold()).tint(pine)
            HStack { Link("アプリについて",destination:URL(string:"https://sites.google.com/view/personal-health-hub-app-info")!); Spacer(); Link("プライバシー",destination:URL(string:"https://sites.google.com/view/personal-health-hub-app-info/privacy")!); Link("利用条件",destination:URL(string:"https://sites.google.com/view/personal-health-hub-app-info/terms")!) }.font(.caption2).foregroundStyle(.secondary).padding(.top,8)
        }.buttonStyle(.plain)
    }
    // モックの「その他」：同じ種類の行を1枚にまとめ、見出しで分ける。
    private func otherSection<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.footnote.bold()).foregroundStyle(.secondary).padding(.leading,4)
            VStack(spacing:0) { rows() }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }
    private func otherRow(_ title: String, _ subtitle: String, _ symbol: String, last: Bool = false) -> some View {
        VStack(spacing:0) {
            HubSettingsRow(title:title,subtitle:subtitle,symbol:symbol).padding(.horizontal,16).padding(.vertical,10)
            if !last { Divider().padding(.leading,56) }
        }
    }
    @ViewBuilder private var connections: some View {
            Card {
                Label("Googleへの接続", systemImage: "externaldrive").font(.headline)
                Text(model.google.authMessage).font(.subheadline).foregroundStyle(.secondary)
                Action(title: model.busy ? "接続しています…" : model.google.connected ? "Googleに再接続" : "Googleでログイン", symbol: "person.crop.circle", disabled: model.previewOnly || model.busy || model.chatGPT.busy) { await model.loginGoogle() }
            }
            Card {
                Label("ChatGPTへの接続", systemImage: "sparkles").font(.headline)
                Text(model.chatGPT.message).font(.subheadline).foregroundStyle(.secondary)
                if model.chatGPT.busy { ProgressView("ログインを確認しています") }
                Action(title: model.chatGPT.signedIn ? "ChatGPTに再接続" : "ChatGPTでログイン", symbol: "person.crop.circle", disabled: model.previewOnly || model.busy || model.chatGPT.busy) { await model.chatGPT.signIn() }
            }
    }
    @ViewBuilder private var syncDetails: some View {
            #if DEBUG
            DisclosureGroup("検証と復旧") {
            Card {
                Label("接続試験（架空データ）", systemImage: "wrench.and.screwdriver").font(.headline)
                Text("通信や認証の失敗をこのアプリ内で模擬します。Googleの権限設定は変更しません。").font(.caption).foregroundStyle(.secondary)
                Action(title: "保存後の応答消失を試す", symbol: "arrow.uturn.backward", disabled: model.busy || !model.pending.isEmpty || !model.google.connected || model.google.debugOffline) { await model.testLostResponse() }
                Toggle("通信断を模擬する（再起動後も保持）", isOn: Binding(get: { model.google.debugOffline }, set: { model.google.debugOffline = $0 })).disabled(model.busy)
                Action(title: "不正な取得結果を試す", symbol: "exclamationmark.triangle", disabled: model.busy || !model.pending.isEmpty || !model.google.connected || model.google.debugOffline) { await model.testInvalidDelta() }
                Action(title: "競合する更新を試す", symbol: "arrow.triangle.branch", disabled: model.busy || !model.pending.isEmpty || model.meals.isEmpty || !model.google.connected || model.google.debugOffline) { await model.testConflict() }
                Action(title: "不正な入力を試す", symbol: "minus.circle", disabled: model.busy || !model.pending.isEmpty) { await model.testInvalidInput() }
                Action(title: "認証切れを模擬して記録する", symbol: "person.crop.circle.badge.exclamationmark", disabled: model.busy || !model.pending.isEmpty || !model.google.connected || model.google.debugOffline) { await model.testAuthenticationLoss() }
            }
            }
            #endif
            if !model.pending.isEmpty {
                Card {
                    Label("送信待ち", systemImage: "tray").font(.headline)
                    ForEach(model.pending) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.operation.payload?.name ?? (item.operation.requiresHealthContract ? "健康データの写し" : item.operation.requiresPlanningContract ? "目標・サプリの変更" : "食事の取消")).font(.subheadline.bold())
                            Text(item.message).font(.subheadline).foregroundStyle(.secondary)
                            if [.conflict, .invalid].contains(item.state) {
                                // 要確認が先頭にあると後ろの送信も止まるため、本番でも「もう一度送る」「破棄」を選べるようにする。
                                HStack {
                                    Button("もう一度送る") { Task { await model.retryRejected(item.id) } }.buttonStyle(.bordered)
                                    Button("破棄", role: .destructive) { model.discardRejected(item.id) }.buttonStyle(.bordered)
                                }.disabled(model.busy).font(.subheadline)
                                Text("破棄しても、確定した記録は変わりません。必要なら記録し直してください。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
    }
}
