import Observation
import PHHHubCore
import SwiftUI

@MainActor @Observable final class FoodScreenModel {
  private let store: any FoodEditingStore
  private let onSaved: (() -> Void)?
  private(set) var state: FoodScreenSnapshot
  var message = ""
  var lastAddition: (operation: String, meal: String)?
  init(store: FoodLocalStore) {
    self.store = store;onSaved=nil
    state = try! store.snapshot()
  }
  init(store: FoodHubStore, onSaved: @escaping () -> Void) throws {
    self.store=store;self.onSaved=onSaved;state=try store.snapshot()
  }
  var canSimulateReceipt:Bool {store is FoodLocalStore}
  func refresh() throws {state=try store.snapshot()}
  func perform(_ action: () throws -> Void) {
    do {
      try action()
      state = try store.snapshot()
      onSaved?()
    } catch { message = error.localizedDescription }
  }
  func add(_ preset: String, date: String, slot: String) {
    perform {
      let id = try store.addPreset(preset, date: date, slot: slot)
      lastAddition = (id, try store.snapshot().pending.first { $0.id == id }!.meal.id)
      message = "追加しました · 端末に保存済み"
    }
    Haptics.emit(.lightPress)
  }
  func undo() {
    guard let last = lastAddition else { return }
    perform {
      if state.pending.contains(where: { $0.id == last.operation }) {
        try store.undoAddition(last.operation)
      } else {
        try store.edit(last.meal,factor:1,date:nil,slot:nil,remove:true)
      }
      lastAddition = nil
      message = "取り消しを端末に保存しました"
    }
  }
  func edit(_ meal: FoodMeal, factor: Double, date: String, slot: String) {
    perform {
      try store.edit(meal.id, factor: factor, date: date, slot: slot,remove:false)
      message = "変更を端末に保存しました"
    }
  }
  func remove(_ meal: FoodMeal) {
    perform {
      try store.edit(meal.id,factor:1,date:nil,slot:nil,remove:true)
      message = "取消を端末に保存しました"
    }
  }
  func confirm(_ draft: FoodDraft, date: String, slot: String, identity: String? = nil) throws {
    let saved = try FoodCommit.confirm(draft, date: date, slot: slot, store: store, identity: identity)
    lastAddition = (saved.operationID, saved.mealID)
    if let snapshot = saved.snapshot { state = snapshot }
    message = saved.snapshot == nil ? "食事は端末に保存済みです。表示の取得に失敗したため前回値を保持しています。同期後に再表示します。" : "確認した食事を端末に保存しました"
    onSaved?()
  }
  func save(_ catalog: FoodCatalog) throws {
    let snapshot = try FoodCommit.saveCatalog(catalog, store: store)
    if let snapshot { state = snapshot }
    message = snapshot == nil ? "プリセットは端末に保存済みです。表示の取得に失敗したため前回値を保持しています。同期後に再表示します。" : "プリセットを端末に保存しました"
    onSaved?()
  }
  #if DEBUG
    func simulateReceipt() {
      perform {
        guard let store=store as? FoodLocalStore else {return}
        for op in store.state.pending where op.state != .needsReview {
          let sent = try store.beginSending(op.id)
          try store.acknowledge(op.id, confirmed: sent.meal)
        }
        message = "架空の保存結果を受信しました"
      }
    }
  #endif
}
enum FoodDates {
  static var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return c
  }
  static func text(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = calendar.timeZone
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }
  static func date(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = calendar.timeZone
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)!
  }
}
func foodNumber(_ value: Double?) -> String {
  value.map { $0.formatted(.number.precision(.fractionLength(0...4))) } ?? "未設定"
}
struct FoodTotalsView: View {
  private var motion = MotionPolicy()
  let total: FoodTotal
  @Environment(\.dynamicTypeSize) private var textSize
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      AccessibleRow {
        Text(foodNumber(total.known[.kcal])).contentTransition(.numericText()).font(
          .system(size: 38, weight: .semibold, design: .rounded)).animation(Motion.animation(reduceMotion: motion.reduced), value: total.known[.kcal])
        Text("kcal").foregroundStyle(.secondary)
        if !textSize.isAccessibilitySize { Spacer(); Image(systemName: "fork.knife.circle.fill").font(.largeTitle).foregroundStyle(pine) }
      }
      AccessibleRow {
        ForEach([FoodNutrient.protein, .fat, .carbohydrate], id: \.self) { key in
          VStack(alignment: .leading, spacing: 4) {
            Text([.protein: "P", .fat: "F", .carbohydrate: "C"][key]!).font(.caption)
              .foregroundStyle(.secondary)
            Text(foodNumber(total.known[key]) + " g").font(.headline)
            if (total.missing[key] ?? 0) > 0 {
              Text("未設定 \(total.missing[key]!)件").font(.caption2).foregroundStyle(.secondary)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if (total.missing[.kcal] ?? 0) > 0 {
        Text("分かっている分の合計 · カロリー未設定 \(total.missing[.kcal]!)件").font(.caption).foregroundStyle(
          .secondary)
      }
    }
  }
}
struct FoodHubPage: View {
  private var motion = MotionPolicy()
  @Bindable var model: FoodScreenModel
  @Environment(\.dynamicTypeSize) private var textSize
  @State var date: Date
  @State private var slot = "朝食"
  @State private var query = ""
  @State private var category: String?
  @State private var analysis = false
  @State private var editing: FoodMeal?
  @State private var removing: FoodMeal?
  @State private var catalog = false
  var analyze: ((Data?, String) async throws -> FoodDraft)?
  let preview: Bool
  let initialAnalysisNote: String
  let planning:PlanningScreenModel?
  var syncing: Bool
  init(
    model: FoodScreenModel, date: Date, analyze: ((Data?, String) async throws -> FoodDraft)? = nil,
    preview: Bool, initialAnalysisNote: String = "", planning:PlanningScreenModel? = nil, syncing: Bool = false
  ) {
    self.model = model
    self.analyze = analyze
    self.preview = preview
    self.planning=planning
    self.syncing=syncing
    self.initialAnalysisNote = initialAnalysisNote
    _date = State(initialValue: date)
  }
  private var plateAnalyzer: SharedPlateAnalyzer? {
    #if DEBUG
    if preview { return SharedPlatePreviewData.analyze }
    #endif
    return nil
  }
  private var day: String { FoodDates.text(date) }
  var body: some View {
    Page(title: "食事") {
      let projection = try? FoodDayPresentation(date: day, snapshot: model.state)
      let foodTotal = projection?.localTotal ?? FoodTotal.day(day, meals: model.state.confirmed)
      let total = (try? planning?.totalWithSupplements(foodTotal, date: day)) ?? foodTotal
      if preview { Text("架空データ · オフライン操作確認").font(.caption).foregroundStyle(.secondary) }
      HStack {
        Button {
          date = FoodDates.calendar.date(byAdding: .day, value: -1, to: date)!
        } label: {
          Image(systemName: "chevron.left").frame(width: 36, height: 40)
        }.accessibilityLabel("前の日")
        DatePicker("記録する日", selection: $date, displayedComponents: .date).labelsHidden().dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          .environment(\.timeZone, FoodDates.calendar.timeZone)
        Spacer()
        Button {
          date = FoodDates.calendar.date(byAdding: .day, value: 1, to: date)!
        } label: {
          Image(systemName: "chevron.right").frame(width: 36, height: 40)
        }.accessibilityLabel("次の日")
      }
      Card {
        Text("記録上の摂取量").font(.subheadline).foregroundStyle(.secondary)
        FoodTotalsView(total: total)
        if let projection, !projection.pending.isEmpty {
          Text("端末保存・送信待ち \(projection.pending.count)件。要確認の変更は合計に含めていません。").font(.caption).foregroundStyle(.secondary)
        }
        if let days = try? planning?.supplements().days.filter({ $0.date == day && $0.isCounted }), !days.isEmpty {
          Text("サプリ込み · 予定\(days.filter { $0.state == .planned }.count)件／服用確認\(days.filter { $0.state == .confirmed }.count)件").font(.caption).foregroundStyle(.secondary)
        }
        if model.state.catalogPendingCount>0 {Text("食品・プリセットの送信待ち \(model.state.catalogPendingCount)件").font(.caption).foregroundStyle(.secondary)}
      }
      if let planning {
        PlanningDayCard(model:planning,date:day,consumed:planningConsumed(total:foodTotal))
        NavigationLink("カテゴリー内のサプリ・自動計上") { SupplementPage(model:planning,date:day) }
      }
      if !model.message.isEmpty {
        Card {
          Text(model.message).font(.subheadline)
          if model.lastAddition != nil {
            Button("取り消す", systemImage: "arrow.uturn.backward") { model.undo() }.buttonStyle(
              .bordered)
          }
        }.transition(.move(edge: .bottom).combined(with: .opacity)).animation(Motion.animation(reduceMotion: motion.reduced), value: model.message).accessibilityIdentifier("food-feedback")
      }
      if textSize.isAccessibilitySize {
        Picker("記録の区分", selection: $slot) { ForEach(FoodRules.slots, id: \.self) { Text($0) } }.pickerStyle(.menu)
      } else {
        MotionSegments(title: "記録の区分", selection: $slot, options: FoodRules.slots.map { ($0, $0) })
      }
      Button {
        analysis = true
      } label: {
        Label("写真・文章から記録", systemImage: "camera").frame(maxWidth: .infinity).padding(.vertical, 8)
      }.buttonStyle(.borderedProminent)
      HStack {
        Text("いつもの食事").font(.title3.bold())
        Spacer()
        Button {
          catalog = true
        } label: {
          Label("編集", systemImage: "slider.horizontal.3")
        }.accessibilityLabel("プリセットを編集")
      }
      TextField("プリセットを検索", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier(
        "food-preset-search")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          categoryButton("すべて", id: nil)
          ForEach(model.state.catalog.categories.filter { !$0.archived }) { c in
            categoryButton(c.name, id: c.id)
          }
        }
      }
      let presets = model.state.catalog.visiblePresets(query: query, categoryID: category)
      if presets.isEmpty {
        Card {
          if model.state.catalog.presets.isEmpty {
            Label("プリセットはまだありません", systemImage: "tray").foregroundStyle(.secondary)
            Text("よく食べる食品や組合せを登録すると、次から押すだけで記録できます。").font(.caption).foregroundStyle(.secondary)
            Button("食品・プリセットを登録") { catalog = true }.buttonStyle(.bordered)
          } else {
            Label("該当するプリセットがありません", systemImage: "magnifyingglass").foregroundStyle(.secondary)
            Text("検索語やカテゴリーを変えてください。非表示の設定は編集から確認できます。").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      ForEach(presets) { p in
        Button {
          withAnimation(Motion.animation(reduceMotion: motion.reduced)) { model.add(p.id, date: day, slot: slot) }
        } label: {
          HStack(spacing: 14) {
            Image(systemName: p.components.count > 1 ? "square.stack.3d.up" : "leaf").font(.title3)
              .foregroundStyle(pine).frame(width: 42, height: 42).background(
                pine.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
              Text(p.name).font(.headline)
              let total = FoodTotal(items: (try? model.state.catalog.snapshot(p.id)) ?? [])
              Text(
                "\((total.missing[.kcal] ?? 0) > 0 ? (total.known[.kcal] == 0 ? "カロリー未設定" : foodNumber(total.known[.kcal]) + " kcal＋未設定") : foodNumber(total.known[.kcal]) + " kcal") · \(p.components.count)品"
              ).font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(pine)
          }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
        }.buttonStyle(HubPressStyle()).accessibilityLabel("\(p.name)を追加")
      }
      HStack {
        Text("この日の記録").font(.title3.bold())
        Spacer()
        NavigationLink("履歴") { FoodHistoryPage(model: model, initialDate: date, syncing: syncing) }
      }
      ForEach(FoodRules.slots, id: \.self) { section in
        let meals = model.state.confirmed.filter {
          !$0.removed && $0.date == day && $0.slot == section
        }
        if !meals.isEmpty {
          Text(section).font(.subheadline.bold()).foregroundStyle(.secondary)
          ForEach(meals) { meal in
            Card {
              FoodMealContents(meal: meal)
              HStack {
                Button("量・日付を変更") { editing = meal }
                Spacer()
                Button("取消", role: .destructive) { removing = meal }
              }.font(.subheadline).disabled(model.state.pending.contains { $0.meal.id == meal.id })
            }
          }
        }
      }
      if model.state.confirmed.filter({ !$0.removed && $0.date == day }).isEmpty {
        Card { Text("確定した食事はありません").foregroundStyle(.secondary) }
      }
      if let projection, !projection.pending.isEmpty {
        Text("端末に保存済み · 送信待ち").font(.title3.bold())
        ForEach(projection.pending) { op in
          Card {
            FoodMealContents(meal: op.meal)
            Text(op.meal.removed ? "取消の送信待ち" : "保存の送信待ち").foregroundStyle(.secondary)
            if op.undoRequested { Text("保存結果を受信してから取り消します").font(.caption) }
            if let error = op.error { Text("要確認：\(error)").foregroundStyle(.red) }
          }
        }
      }
      #if DEBUG
        if preview && model.canSimulateReceipt {
          Button("架空の保存結果を受信") { model.simulateReceipt() }.buttonStyle(.bordered)
            .accessibilityIdentifier("food-simulate-receipt")
        }
      #endif
    }.animation(Motion.animation(reduceMotion: motion.reduced), value: model.state.confirmed.filter { !$0.removed }.map(\.id))
    .sheet(isPresented: $analysis) {
      NavigationStack {
        FoodAnalysisPage(date: day, slot: slot, analyze: analyze, initialNote: initialAnalysisNote, plateAnalyze: plateAnalyzer, platePreview: preview, plateSave: { draft, day, mealSlot, identity in try model.confirm(draft, date: day, slot: mealSlot, identity: identity) })
        { draft in
          try model.confirm(draft, date: day, slot: slot)
        }
      }
    }.sheet(item: $editing) { meal in
      NavigationStack {
        FoodMealEditor(meal: meal) { factor, d, s in
          model.edit(meal, factor: factor, date: d, slot: s)
        }
      }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }.sheet(isPresented: $catalog) { NavigationStack { FoodCatalogPage(model: model) } }
      .confirmationDialog(
        "\(removing?.date ?? "")の\(removing?.items.map(\.name).joined(separator:"・") ?? "食事")を取り消しますか",
        isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
        titleVisibility: .visible
      ) {
        Button("この食事を取り消す", role: .destructive) {
          if let removing { Haptics.emit(.lightPress); withAnimation(Motion.animation(reduceMotion: motion.reduced)) { model.remove(removing) } }
          removing = nil
        }
      }
  }
  private func categoryButton(_ title: String, id: String?) -> some View {
    Button {
      category = id
    } label: {
      Text(title).font(.subheadline).padding(.horizontal, 14).padding(.vertical, 9).foregroundStyle(
        category == id ? Color(uiColor: .systemBackground) : pine
      ).background(category == id ? pine : pine.opacity(0.08), in: Capsule())
    }.buttonStyle(.plain)
  }
}
struct FoodMealContents: View {
  let meal: FoodMeal
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(meal.items.enumerated()), id: \.element.id) { order, i in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            Text(i.name).font(.headline)
            Text("\(foodNumber(i.quantity))\(i.unit) · \(i.source)").font(.caption).foregroundStyle(
              .secondary)
          }
          Spacer()
          Text("\(foodNumber(i.nutrients.kcal)) kcal").font(.subheadline.monospacedDigit())
        }.motionReveal(order: order)
      }
      Text("\(meal.date) · \(meal.slot) · 版\(meal.revision)").font(.caption2).foregroundStyle(
        .secondary)
    }
  }
}
struct FoodMealEditor: View {
  private var motion = MotionPolicy()
  let meal: FoodMeal, save: (Double, String, String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var factor = "1"
  @State private var date: Date
  @State private var slot: String
  @State private var error = ""
  @State private var increasing = true
  init(meal: FoodMeal, save: @escaping (Double, String, String) -> Void) {
    self.meal = meal
    self.save = save
    _date = State(initialValue: FoodDates.date(meal.date))
    _slot = State(initialValue: meal.slot)
  }
  var body: some View {
    Form {
      Section("記録時の量を基準に変更") {
        FoodMealContents(meal: meal)
        LabeledContent("倍率") {
          TextField("1", text: $factor).motionFieldError(error).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            .accessibilityIdentifier("food-edit-factor")
        }
        AccessibleRow {
          Button { changeFactor(-0.5) } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }.buttonStyle(.borderless).accessibilityLabel("量を0.5倍減らす")
          ForEach([0.5, 1.0, 2.0], id: \.self) { n in
            Button("\(foodNumber(n))倍") { setFactor(n) }.buttonStyle(.bordered)
          }
          Button { changeFactor(0.5) } label: { Image(systemName: "plus.circle").frame(minWidth: 44, minHeight: 44) }.buttonStyle(.borderless).accessibilityLabel("量を0.5倍増やす")
        }
        Text(factor + "倍").font(.title2.monospacedDigit()).padding(10).background(pine.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          .id(factor).transition(.asymmetric(insertion: .move(edge: increasing ? .trailing : .leading).combined(with: .opacity), removal: .opacity))
        if let n = Double(factor), let edited = try? meal.edited(factor: n) {
          FoodTotalsView(total: .init(items: edited.items))
        }
        Text("現在のプリセットではなく、この食事に保存された値から計算します。").font(.caption).foregroundStyle(.secondary)
      }
      Section("移動先") {
        DatePicker("日付", selection: $date, displayedComponents: .date).environment(
          \.timeZone, FoodDates.calendar.timeZone)
        Picker("区分", selection: $slot) { ForEach(FoodRules.slots, id: \.self) { Text($0) } }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.navigationTitle("食事を変更").navigationBarTitleDisplayMode(.inline).toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") {
          do {
            guard let n = Double(factor) else { throw FoodFailure.invalidValue }
            _ = try meal.edited(factor: n, date: FoodDates.text(date), slot: slot)
            save(n, FoodDates.text(date), slot)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }
      }
    }
  }
  private func changeFactor(_ delta: Double) { guard let current = Double(factor) else { return }; setFactor(max(0.1, current + delta)) }
  private func setFactor(_ value: Double) {
    increasing = value >= (Double(factor) ?? value)
    withAnimation(Motion.animation(reduceMotion: motion.reduced)) { factor = foodNumber(value) }
    Haptics.emit(.selection)
  }
}
struct FoodHistoryPage: View {
  @Bindable var model: FoodScreenModel
  @State var date: Date
  var syncing = false
  @State private var editing: FoodMeal?
  @State private var removing: FoodMeal?
  private var motion = MotionPolicy()
  init(model: FoodScreenModel, initialDate: Date, syncing: Bool = false) {
    self.syncing = syncing
    self.model = model
    _date = State(initialValue: initialDate)
  }
  var body: some View {
    Page(title: "食事の履歴") {
      DatePicker("日付", selection: $date, displayedComponents: .date).environment(
        \.timeZone, FoodDates.calendar.timeZone)
      Card { FoodTotalsView(total: .day(FoodDates.text(date), meals: model.state.confirmed)) }
      if syncing { MotionSkeleton() }
      ForEach(FoodRules.slots, id: \.self) { slot in
        let meals = model.state.confirmed.filter {
          !$0.removed && $0.date == FoodDates.text(date) && $0.slot == slot
        }
        if !meals.isEmpty {
          Text(slot).font(.title3.bold())
          ForEach(meals) { meal in Card {
            FoodMealContents(meal: meal)
            MotionRowMenu(title: meal.items.map(\.name).joined(separator: "・")) {
              Button("量・日付を変更") { editing=meal }
              Button("取消", role: .destructive) { removing=meal }
            }.disabled(model.state.pending.contains { $0.meal.id == meal.id })
          }.transition(.move(edge: .trailing).combined(with: .opacity)) }
        }
      }
      if model.state.confirmed.filter({ !$0.removed && $0.date == FoodDates.text(date) }).isEmpty {
        ContentUnavailableView("記録がありません", systemImage: "calendar")
      }
    }.animation(Motion.animation(reduceMotion: motion.reduced), value: model.state.confirmed.filter { !$0.removed }.map(\.id))
      .sheet(item: $editing) { meal in NavigationStack { FoodMealEditor(meal: meal) { factor, date, slot in model.edit(meal, factor: factor, date: date, slot: slot) } }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
      .confirmationDialog("この食事を取り消しますか", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing=nil } })) {
        Button("この食事を取り消す", role: .destructive) { if let removing { model.remove(removing) }; removing=nil }
      }
  }
}
struct FoodCatalogPage: View {
  @Bindable var model: FoodScreenModel
  @Environment(\.dismiss) private var dismiss
  @State private var newPreset = false
  @State private var newFood = false
  @State private var versionEditing: FoodVersion?
  @State private var newCategory = false
  @State private var categoryName = ""
  @State private var editing: FoodPreset?
  @State private var error = ""
  var body: some View {
    List {
      Section("食品の版") {
        ForEach(model.state.catalog.versions) { v in
          Button { versionEditing = v } label: {
          VStack(alignment: .leading) {
            Text(v.name).font(.headline)
            Text("\(foodNumber(v.quantity))\(v.unit) · \(v.preparation) · 版\(v.revision)").font(
              .caption
            ).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
        Button("食品を追加") { newFood = true }
      }
      Section("プリセット") {
        ForEach(model.state.catalog.presets) { p in
          Button {
            editing = p
          } label: {
            HStack {
              Text(p.name)
              Spacer()
              Text(p.archived ? "非表示" : "版\(p.revision)").foregroundStyle(.secondary)
            }
          }
        }
        Button("プリセットを作成") { newPreset = true }
      }
      Section("カテゴリー") {
        ForEach(model.state.catalog.categories) { c in
          HStack {
            Text(c.name)
            Spacer()
            Button(c.archived ? "表示する" : "非表示にする") {
              model.perform {
                var copy = c
                copy.archived.toggle()
                var catalog = model.state.catalog
                try catalog.save(copy)
                try model.save(catalog)
              }
            }.font(.caption)
          }
        }
        Button("カテゴリーを作成") { newCategory = true }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.navigationTitle("食品・プリセット").navigationBarTitleDisplayMode(.inline).toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
    }.sheet(isPresented: $newFood) {
      NavigationStack {
        FoodVersionEditor { version in
          var catalog = model.state.catalog
          try catalog.add(version)
          try model.save(catalog)
        }
      }
    }.sheet(item: $versionEditing) { version in
      NavigationStack {
        FoodVersionEditor(
          prior: version,
          nextRevision: (model.state.catalog.versions.filter { $0.foodID == version.foodID }.map(
            \.revision
          ).max() ?? 0) + 1
        ) { next in
          var catalog = model.state.catalog
          try catalog.add(next)
          try model.save(catalog)
        }
      }
    }.sheet(isPresented: $newPreset) {
      NavigationStack {
        FoodPresetEditor(catalog: model.state.catalog) { preset in
          var catalog = model.state.catalog
          try catalog.save(preset)
          try model.save(catalog)
        }
      }
    }.sheet(item: $editing) { p in
      NavigationStack {
        FoodPresetEditor(catalog: model.state.catalog, preset: p) { preset in
          var catalog = model.state.catalog
          try catalog.save(preset)
          try model.save(catalog)
        }
      }
    }.alert("カテゴリーを作成", isPresented: $newCategory) {
      TextField("名前", text: $categoryName)
      Button("作成") {
        do {
          var catalog = model.state.catalog
          try catalog.save(.init(name: categoryName))
          try model.save(catalog)
          categoryName = ""
        } catch { self.error = error.localizedDescription }
      }
      Button("取消", role: .cancel) {}
    }
  }
}
struct FoodVersionEditor: View {
  let save: (FoodVersion) throws -> Void
  let prior: FoodVersion?
  let nextRevision: Int
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var quantity = "1"
  @State private var unit = "個"
  @State private var preparation = "未指定"
  @State private var source = "商品表示"
  @State private var kcal = ""
  @State private var protein = ""
  @State private var fat = ""
  @State private var carbs = ""
  @State private var error = ""
  init(
    prior: FoodVersion? = nil, nextRevision: Int = 1, save: @escaping (FoodVersion) throws -> Void
  ) {
    self.prior = prior
    self.nextRevision = nextRevision
    self.save = save
    _name = State(initialValue: prior?.name ?? "")
    _quantity = State(initialValue: prior.map { String($0.quantity) } ?? "1")
    _unit = State(initialValue: prior?.unit ?? "個")
    _preparation = State(initialValue: prior?.preparation ?? "未指定")
    _source = State(initialValue: prior?.source ?? "商品表示")
    _kcal = State(initialValue: prior?.nutrients.kcal.map { String($0) } ?? "")
    _protein = State(initialValue: prior?.nutrients.protein.map { String($0) } ?? "")
    _fat = State(initialValue: prior?.nutrients.fat.map { String($0) } ?? "")
    _carbs = State(initialValue: prior?.nutrients.carbohydrate.map { String($0) } ?? "")
  }
  var body: some View {
    Form {
      Section("表示する量") {
        LabeledContent("食品名") { TextField("食品名", text: $name) }
        LabeledContent("基準量") { TextField("基準量", text: $quantity).keyboardType(.decimalPad) }
        LabeledContent("単位（個・gなど）") { TextField("単位（個・gなど）", text: $unit) }
        LabeledContent("調理状態") { TextField("調理状態", text: $preparation) }
        Picker("出典", selection: $source) {
          ForEach(["商品表示", "成分表", "本人", "推定"], id: \.self) { Text($0) }
        }
      }
      Section("基準量の栄養 · 空欄は未設定") {
        LabeledContent("kcal") { TextField("kcal", text: $kcal).keyboardType(.decimalPad) }
        LabeledContent("P（g）") { TextField("P（g）", text: $protein).keyboardType(.decimalPad) }
        LabeledContent("F（g）") { TextField("F（g）", text: $fat).keyboardType(.decimalPad) }
        LabeledContent("C（g）") { TextField("C（g）", text: $carbs).keyboardType(.decimalPad) }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.navigationTitle(prior == nil ? "食品を追加" : "食品の新しい版").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            do {
              func number(_ s: String) throws -> Double? {
                if s.isEmpty { return nil }
                guard let d = Double(s) else { throw FoodFailure.invalidValue }
                return d
              }
              guard let q = Double(quantity) else { throw FoodFailure.invalidValue }
              try save(
                .init(
                  foodID: prior?.foodID ?? UUID().uuidString, revision: nextRevision,
                  name: name, quantity: q, unit: unit, preparation: preparation, source: source,
                  nutrients: .init(
                    kcal: number(kcal), protein: number(protein), fat: number(fat),
                    carbohydrate: number(carbs))))
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        }
      }
  }
}
struct FoodPresetEditor: View {
  let catalog: FoodCatalog, preset: FoodPreset?, save: (FoodPreset) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var category: String
  @State private var selected: [String: Double]
  @State private var archived: Bool
  @State private var error = ""
  init(catalog: FoodCatalog, preset: FoodPreset? = nil, save: @escaping (FoodPreset) throws -> Void)
  {
    self.catalog = catalog
    self.preset = preset
    self.save = save
    _name = State(initialValue: preset?.name ?? "")
    _category = State(initialValue: preset?.categoryID ?? "")
    _selected = State(
      initialValue: Dictionary(
        (preset?.components ?? []).map { ($0.versionID, $0.factor) }, uniquingKeysWith: +))
    _archived = State(initialValue: preset?.archived ?? false)
  }
  var body: some View {
    Form {
      Section("プリセット") {
        TextField("名前", text: $name)
        Picker("カテゴリー", selection: $category) {
          Text("分類なし").tag("")
          ForEach(catalog.categories) { Text($0.name).tag($0.id) }
        }
        Toggle("一覧から非表示", isOn: $archived)
      }
      Section("組み合わせる食品の版") {
        ForEach(catalog.versions) { v in
          VStack(alignment: .leading) {
            Toggle(
              "\(v.name) · 版\(v.revision)",
              isOn: Binding(get: { selected[v.id] != nil }, set: { selected[v.id] = $0 ? 1 : nil }))
            if selected[v.id] != nil {
              Stepper(
                value: Binding(get: { selected[v.id] ?? 1 }, set: { selected[v.id] = $0 }),
                in: 0.25...100, step: 0.25
              ) {
                Text("\(foodNumber(v.quantity*(selected[v.id] ?? 1)))\(v.unit)").font(.subheadline)
              }
            }
          }
        }
      }
      Text("変更はこれから登録する食事に適用されます。過去の食事は保持します。").font(.caption).foregroundStyle(.secondary)
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.navigationTitle(preset == nil ? "プリセットを作成" : "プリセットを変更").navigationBarTitleDisplayMode(
      .inline
    ).toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") {
          do {
            let p = try FoodPreset(
              id: preset?.id ?? UUID().uuidString, revision: (preset?.revision ?? 0) + 1,
              name: name, categoryID: category.isEmpty ? nil : category,
              components: selected.keys.sorted().map {
                try .init(versionID: $0, factor: selected[$0]!)
              }, archived: archived)
            try save(p)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }
      }
    }
  }
}
