import SwiftUI
import UIKit
import PHHHubCore

let pine = Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(red: 0.60, green: 0.82, blue: 0.70, alpha: 1) : UIColor(red: 0.13, green: 0.34, blue: 0.28, alpha: 1) })
let canvas = Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? .systemGroupedBackground : UIColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1) })

struct HubRoot: View {
    let model: HubModel
    @Environment(\.scenePhase) private var phase
    var body: some View {
        TabView {
            NavigationStack { HomePage(model: model) }.tabItem { Label("ホーム", systemImage: "house.fill") }
            NavigationStack {
                if model.foodWriteEnabled,let food=model.foodScreen { FoodHubPage(model:food,date:FoodDates.date(model.date),analyze:nil,preview:false,planning:model.planningScreen,syncing:model.busy) }
                else { FoodPage(model:model) }
            }.tabItem { Label("食事", systemImage: "fork.knife") }
            NavigationStack { OtherPage(model: model) }.tabItem { Label("その他", systemImage: "ellipsis") }
        }
        .tint(pine)
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
            .background(canvas).navigationTitle(title).navigationBarTitleDisplayMode(.large)
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
    var body: some View {
        Card {
            HStack { MotionSyncSymbol(busy: model.busy, succeeded: model.message.hasPrefix("同期しました")); Text(model.busy ? "同期しています" : "同期状態"); Spacer(); if model.busy { MotionDots() } }
            Text(model.message).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("sync-message")
            if !model.pending.isEmpty { Label("送信待ち \(model.pending.count)件", systemImage: "tray").font(.subheadline) }
            Action(title: model.busy ? "確認しています…" : "今すぐ同期", symbol: "arrow.clockwise", disabled: model.busy || !model.google.connected) { await model.synchronize(forceQueued: true) }
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
        if let total { return total.known[nutrient] }
        return model.summary?.values[field]?.number
    }
    var body: some View {
        Page(title: "今日の記録") {
            let food = self.food
            let total = food.map { projection in (try? model.planningScreen?.totalWithSupplements(projection.localTotal, date: model.date)) ?? projection.localTotal }
            let goal = self.goal
            let unknown = total.map { $0.missing.values.contains { $0 > 0 } } ?? model.summary.map { summary in ["kcal_unknown", "protein_unknown", "fat_unknown", "carbohydrate_unknown"].contains { (summary.values[$0]?.number ?? 0) > 0 } } ?? false
            AccessibleRow { Text(model.date).font(.subheadline).foregroundStyle(.secondary); if !textSize.isAccessibilitySize { Spacer() }; Label("接続確認", systemImage: "leaf").font(.caption).foregroundStyle(pine) }
            Card {
                ZStack {
                    if !textSize.isAccessibilitySize { MotionIntakeRing(fraction: goal?.total.kcal.flatMap { target in target > 0 ? amount(.kcal, field: "kcal", total: total).map { $0 / target } : nil }).frame(width: 218, height: 218) }
                    VStack(spacing: 8) {
                        Text("記録上の摂取").font(.subheadline)
                        HStack(alignment: .firstTextBaseline, spacing: 4) { Text(number(amount(.kcal, field: "kcal", total: total))).font(.system(size: 42, weight: .semibold, design: .rounded)).contentTransition(.numericText()).animation(Motion.animation(reduceMotion: motion.reduced), value: amount(.kcal, field: "kcal", total: total)); Text("kcal").font(.subheadline) }
                        Text(goal.map { "目標 \(number($0.total.kcal)) kcal" } ?? "目標は未設定").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
                AccessibleRow(spacing: 0) {
                    Macro(title: "たんぱく質", symbol: "P", value: amount(.protein, field: "protein_g", total: total))
                    if !textSize.isAccessibilitySize { Divider().frame(height: 48) }
                    Macro(title: "脂質", symbol: "F", value: amount(.fat, field: "fat_g", total: total))
                    if !textSize.isAccessibilitySize { Divider().frame(height: 48) }
                    Macro(title: "炭水化物", symbol: "C", value: amount(.carbohydrate, field: "carbohydrate_g", total: total))
                }
                if unknown {
                    Text("不明な栄養値があります。表示は分かっている値の合計です。").font(.caption).foregroundStyle(.secondary)
                }
                if let food, !food.pending.isEmpty { Text("端末保存・送信待ち \(food.pending.count)件。要確認の変更は合計に含めていません。").font(.caption).foregroundStyle(.secondary) }
                if let days = try? model.planningScreen?.supplements().days.filter({ $0.date == model.date && $0.isCounted }), !days.isEmpty { Text("サプリ込み · 予定\(days.filter { $0.state == .planned }.count)件／服用確認\(days.filter { $0.state == .confirmed }.count)件").font(.caption).foregroundStyle(.secondary) }
            }
            if let planning=model.planningScreen {
                PlanningDayCard(model:planning,date:model.date,consumed:food.map { planningConsumed(total: $0.localTotal) } ?? planningConsumed(summary:model.summary))
            }
            Card {
                Label("トレーニング", systemImage: "dumbbell").font(.headline)
                NavigationLink("カレンダーとCycleを見る") { TrainingCalendarPage(snapshot:model.trainingSnapshot,status:model.message,reference:model.trainingCycles.first,date:FoodDates.date(model.date),cycles:model.trainingCycles,saveReference:model.trainingWriteEnabled ? { await model.registerTrainingCycle($0) }:nil,updateSession:model.trainingWriteEnabled ? { await model.updateTrainingSession($0,state:$1,cycle:$2,slot:$3) }:nil).motionZoom(id: "training", in: cardZoom, reduced: motion.reduced) }.matchedTransitionSource(id: "training", in: cardZoom)
                if model.training.isEmpty { Text("今日の確定記録はまだありません").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(model.training) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.values["exercise"]?.text ?? "トレーニング記録").font(.headline)
                        if row.table == "TrainingSets" { Text("セット\(number(row.values["set_no"]?.number)) · \(number(row.values["weight_kg"]?.number))kg × \(number(row.values["reps"]?.number))").font(.subheadline) }
                        else { Text(row.values["text"]?.text ?? row.values["note"]?.text ?? "補足記録").font(.subheadline) }
                        Text("版\(row.revision)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let health=model.healthScreen { HealthHomeCard(screen:health,autoSleep:model.autoSleepDeliveries,readEnabled:model.healthReadEnabled,readPrepared:model.healthReadPrepared,connect:{ await model.connectHealth() },refresh:{ await model.catchUpHealth() }) }
            SyncCard(model: model)
        }
    }
}
private struct Macro: View {
    let title: String; let symbol: String; let value: Double?
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text("\(symbol) \(number(value))g").font(.headline) }.frame(maxWidth: .infinity) }
}
private struct FoodPage: View {
    let model: HubModel
    var body: some View {
        Page(title: "食事") {
            Text("\(model.date) · 接続確認用の架空データ").font(.subheadline).foregroundStyle(.secondary)
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
                    HStack(alignment: .firstTextBaseline) { Text(meal.values["slot"]?.text ?? "食事").font(.caption).foregroundStyle(pine); Spacer(); Text("版\(meal.revision)").font(.caption).foregroundStyle(.secondary) }
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
        Page(title: "その他") {
            if let health=model.healthScreen { Card { NavigationLink { HealthDetailPage(screen:health,autoSleep:model.autoSleepDeliveries,readEnabled:model.healthReadEnabled,readPrepared:model.healthReadPrepared,connect:{await model.connectHealth()},refresh:{await model.catchUpHealth()}) } label: { Label("健康データと体重",systemImage:"heart.text.clipboard") } } }
            Card { NavigationLink { TrainingCalendarPage(snapshot:model.trainingSnapshot,status:model.message,reference:model.trainingCycles.first,date:FoodDates.date(model.date),cycles:model.trainingCycles,saveReference:model.trainingWriteEnabled ? { await model.registerTrainingCycle($0) }:nil,updateSession:model.trainingWriteEnabled ? { await model.updateTrainingSession($0,state:$1,cycle:$2,slot:$3) }:nil) } label: { Label("トレーニング",systemImage:"calendar") };NavigationLink { TrainingGradesPage(snapshot:model.trainingSnapshot,date:FoodDates.date(model.date)) } label: { Label("種目の成績",systemImage:"chart.xyaxis.line") } }
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
            SyncCard(model: model)
            #if DEBUG
            Card {
                Label("接続試験（架空データ）", systemImage: "wrench.and.screwdriver").font(.headline)
                Text("通信や認証の失敗をこのアプリ内で模擬します。Googleの権限設定は変更しません。").font(.caption).foregroundStyle(.secondary)
                Action(title: "保存後の応答消失を試す", symbol: "arrow.uturn.backward", disabled: model.busy || !model.pending.isEmpty || !model.google.connected || model.google.debugOffline) { await model.testLostResponse() }
                Toggle("通信断を模擬する（再起動後も保持）", isOn: Binding(get: { model.google.debugOffline }, set: { model.google.debugOffline = $0 })).disabled(model.busy)
                Action(title: "不正な取得結果を試す", symbol: "exclamationmark.triangle", disabled: model.busy || !model.pending.isEmpty || !model.google.connected || model.google.debugOffline) { await model.testInvalidDelta() }
                Action(title: "版が一致しない更新を試す", symbol: "arrow.triangle.branch", disabled: model.busy || !model.pending.isEmpty || model.meals.isEmpty || !model.google.connected || model.google.debugOffline) { await model.testConflict() }
                Action(title: "不正な入力を試す", symbol: "minus.circle", disabled: model.busy || !model.pending.isEmpty) { await model.testInvalidInput() }
                Action(title: "認証切れを模擬して記録する", symbol: "person.crop.circle.badge.exclamationmark", disabled: model.busy || !model.pending.isEmpty || !model.google.connected || model.google.debugOffline) { await model.testAuthenticationLoss() }
            }
            #endif
            if !model.pending.isEmpty {
                Card {
                    Label("送信待ち", systemImage: "tray").font(.headline)
                    ForEach(model.pending) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.operation.payload?.name ?? (item.operation.requiresHealthContract ? "健康データの写し" : item.operation.requiresPlanningContract ? "目標・サプリの変更" : "食事の取消")).font(.subheadline.bold())
                            Text(item.message).font(.subheadline).foregroundStyle(.secondary)
                            #if DEBUG
                            if [.conflict, .invalid].contains(item.state) {
                                Button("この要確認の試験操作を破棄", role: .destructive) { model.discardRejected(item.id) }.disabled(model.busy)
                            }
                            #endif
                        }
                    }
                }
            }
            Card {
                Link("アプリについて", destination: URL(string: "https://sites.google.com/view/personal-health-hub-app-info")!)
                Link("プライバシーポリシー", destination: URL(string: "https://sites.google.com/view/personal-health-hub-app-info/privacy")!)
                Link("利用条件", destination: URL(string: "https://sites.google.com/view/personal-health-hub-app-info/terms")!)
            }
        }
    }
}
