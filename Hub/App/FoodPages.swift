import Observation
import PHHHubCore
import SwiftUI

@MainActor @Observable final class FoodScreenModel {
  private let store: any FoodEditingStore
  private let onSaved: (() -> Void)?
  private(set) var state: FoodScreenSnapshot
  var message = ""
  var lastAddition: (operation: String, meal: String)?
  private(set) var lastUndo: FoodUndoChange?
  // 取り消しの帯の文は帯ごとに持つ。後から起きたエラー文で上書きされ、取り消しの対象を取り違えないため（10/4）。
  private(set) var undoText = ""
  init(store: FoodLocalStore) {
    self.store = store;onSaved=nil
    state = try! store.snapshot()
  }
  init(store: FoodHubStore, onSaved: @escaping () -> Void) throws {
    self.store=store;self.onSaved=onSaved;state=try store.snapshot()
  }
  var canSimulateReceipt:Bool {store is FoodLocalStore}
  func editingBlocked(_ mealID:String) -> Bool {
    let related=state.pending.filter {$0.meal.id==mealID}
    return related.contains {$0.state == .needsReview || $0.undoRequested}
      || (!store.permitsQueuedEdits && !related.isEmpty)
  }
  func saveStatus(_ mealID:String) -> String? {
    // 内部の言葉を出さない（DESIGN 2.6）。失敗は別に「要確認」で出す。
    if state.pending.contains(where:{$0.meal.id==mealID}) {return "同期待ち"}
    if state.acknowledged.contains(where:{$0.id==mealID}) {return "同期中"}
    return nil
  }
  func refresh() throws {state=try store.snapshot()}
  @discardableResult func perform(_ action: () throws -> Void) -> Bool {
    do {
      try action()
      state = try store.snapshot()
      onSaved?(); return true
    } catch { message = error.localizedDescription; return false }
  }
  func add(_ preset: String, date: String, slot: String) {
    do {
      guard let p=state.catalog.presets.first(where: { $0.id == preset && !$0.archived }) else { throw FoodFailure.missingReference }
      let meal=try FoodMeal(date: date, slot: slot, items: state.catalog.snapshot(preset), presetID: p.id, presetRevision: p.revision)
      applySaved(try FoodCommit.enqueueMeal(meal, store: store), before: nil, text: "「\(p.name)」を\(slot)に追加しました")
      Haptics.emit(.lightPress)
    } catch { message=error.localizedDescription }
  }
  func undo() {
    guard let change=lastUndo, change.available() else { return }
    if perform({ try store.undoChange(change, at: .now); message="元に戻しました" }) {
      lastUndo=nil; lastAddition=nil
    }
  }
  func expireUndo(_ operationID: String) { if lastUndo?.operationID == operationID { lastUndo=nil } }
  private func applySaved(_ saved: FoodCommit.SavedMeal, before: FoodMeal?, text: String) {
    if let snapshot=saved.snapshot { state=snapshot }
    lastUndo=try? FoodUndoChange(operationID: saved.operationID, before: before, after: saved.meal); undoText=text
    if before == nil { lastAddition=(saved.operationID, saved.mealID) }
    message=saved.snapshot == nil ? "変更は端末に保存済みです。表示の取得に失敗したため前回値を保持しています。同期後に再表示します。" : text
    onSaved?()
  }
  func edit(_ meal: FoodMeal, factor: Double, date: String, slot: String) {
    do { let next=try meal.edited(factor: factor, date: date, slot: slot); applySaved(try FoodCommit.enqueueMeal(next, store: store), before: meal, text: "「\(meal.items.first?.name ?? "食事")」を変更しました") }
    catch { message=error.localizedDescription }
  }
  func remove(_ meal: FoodMeal) {
    do { let next=try meal.edited(remove: true); applySaved(try FoodCommit.enqueueMeal(next, store: store), before: meal, text: "「\(meal.items.first?.name ?? "食事")」を取り消しました") }
    catch { message=error.localizedDescription }
  }
  func confirm(_ draft: FoodDraft, date: String, slot: String, identity: String? = nil) throws {
    let saved = try FoodCommit.confirm(draft, date: date, slot: slot, store: store, identity: identity)
    applySaved(saved, before: nil, text: "確認した食事を記録しました")
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
  value.map { $0.formatted(.number.precision(.fractionLength(0...4))) } ?? "—"
}
struct FoodTotalsView: View {
  private var motion = MotionPolicy()
  let total: FoodTotal
  @Environment(\.dynamicTypeSize) private var textSize
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      AccessibleRow {
        Text(foodNumber(total.displayValue(for:.kcal))).contentTransition(.numericText()).font(
          .system(size: 38, weight: .semibold, design: .rounded)).animation(Motion.animation(reduceMotion: motion.reduced), value: total.displayValue(for:.kcal))
        Text("kcal").foregroundStyle(.secondary)
        if !textSize.isAccessibilitySize { Spacer(); Image(systemName: "fork.knife.circle.fill").font(.largeTitle).foregroundStyle(pine) }
      }
      AccessibleRow {
        ForEach([FoodNutrient.protein, .fat, .carbohydrate], id: \.self) { key in
          VStack(alignment: .leading, spacing: 4) {
            Text([.protein: "P", .fat: "F", .carbohydrate: "C"][key]!).font(.caption)
              .foregroundStyle(.secondary)
              Text(foodNumber(total.displayValue(for:key)) + " g").font(.headline)
            if (total.missing[key] ?? 0) > 0 {
              HubUnknownNutrientsHelp()
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if (total.missing[.kcal] ?? 0) > 0 {
        Text("一部不明 · 分かっている栄養値の合計です").font(.caption).foregroundStyle(
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
  @State private var slot = FoodHubPage.defaultSlot()
  @State private var slotChosen = false
  @State private var chosenOnDay: Date?
  @State private var query = ""
  @FocusState private var searchFocused: Bool
  @State private var category: String?
  @State private var presetMode = PresetDisplayPreferences.mode
  @State private var fixedPresetOrder = PresetDisplayPreferences.fixedOrder
  @State private var searchAliases = FoodSearchPreferences.aliases
  @State private var analysis = false
  @State private var plateOpen = false
  // 並びの計算に使う記録は、画面を開いたとき・前面に戻ったときに取り直す。同期で回数が増えた瞬間に指の下で行が動かないため（10/4）。
  @State private var rankingMeals: [FoodMeal] = []
  @State private var editing: FoodMeal?
  @State private var removing: FoodMeal?
  @State private var unusualPreset: (String, String, String)?
  @State private var catalog = false
  @State private var labelOCR = false
  @State private var dateChosen = false
  @State private var choosingDate = false
  @Environment(\.scenePhase) private var scenePhase
  var analyze: (([Data], String) async throws -> FoodDraft)?
  let preview: Bool
  let initialAnalysisNote: String
  let hydration:HydrationScreenModel?
  let livePlateAnalyzer:SharedPlateAnalyzer?
  let planning:PlanningScreenModel?
  var syncing: Bool
  let implicitDate: Bool
  init(
    model: FoodScreenModel, date: Date, analyze: (([Data], String) async throws -> FoodDraft)? = nil,
    preview: Bool, initialAnalysisNote: String = "", planning:PlanningScreenModel? = nil, syncing: Bool = false,
    implicitDate: Bool = false, hydration:HydrationScreenModel? = nil, plateAnalyze:SharedPlateAnalyzer? = nil
  ) {
    self.model = model
    self.analyze = analyze
    self.preview = preview
    self.hydration=hydration
    self.livePlateAnalyzer=plateAnalyze
    self.planning=planning
    self.syncing=syncing
    self.implicitDate=implicitDate
    self.initialAnalysisNote = initialAnalysisNote
    _date = State(initialValue: implicitDate ? RecordingPreferences.day() : date)
  }
  private var plateAnalyzer: SharedPlateAnalyzer? {
    #if DEBUG
    if preview { return SharedPlatePreviewData.analyze }
    #endif
    return livePlateAnalyzer
  }
  private var day: String { FoodDates.text(date) }
  var body: some View {
    HubMockPage {
      let projection = try? FoodDayPresentation(date: day, snapshot: model.state)
      let foodTotal = projection?.localTotal ?? FoodTotal.day(day, meals: model.state.confirmed)
      let total = (try? planning?.totalWithSupplements(foodTotal, date: day)) ?? foodTotal
      HStack(spacing: 8) {
        Button { dateChosen=true; chosenOnDay=RecordingPreferences.day(); date=FoodDates.calendar.date(byAdding: .day, value: -1, to: date)! } label: { Image(systemName: "chevron.left").frame(width: 32, height: 44) }.accessibilityLabel("前の日")
        Text(mockDay(date)).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
        if implicitDate && date != RecordingPreferences.day() {
          // 今日以外を見ているときだけ出す。押せばすぐ今日へ戻る（10/4）。
          Button("今日に戻る") { dateChosen=false; chosenOnDay=nil; slotChosen=false; refreshImplicitDate() }.font(.caption.bold()).buttonStyle(.bordered).tint(pine)
        }
        Button { dateChosen=true; chosenOnDay=RecordingPreferences.day(); date=FoodDates.calendar.date(byAdding: .day, value: 1, to: date)! } label: { Image(systemName: "chevron.right").frame(width: 32, height: 44) }.accessibilityLabel("次の日")
      }
      // 区分は4つ並びの切替で1タップ（N08）。初期値は時刻から決め、本人が選んだら固定する。
      MotionSegments(title: "記録の区分", selection: Binding(get: { slot }, set: { slot=$0; slotChosen=true }), options: FoodRules.slots.map { ($0, $0) })
      ScrollView(.horizontal, showsIndicators: false) {
        HStack { categoryButton("すべて", id: nil); ForEach(model.state.catalog.categories.filter { !$0.archived }) { c in categoryButton(c.name, id: c.id) } }
      }
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("食べ物を検索", text: $query).accessibilityIdentifier("food-preset-search")
          .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused=false }
        if !query.isEmpty {
          Button { query=""; searchFocused=false } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary).frame(width:32,height:32).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel("検索文字を消す").accessibilityIdentifier("food-preset-clear")
        }
        Menu {
          Button("記録する日を選ぶ") { choosingDate=true }
          Picker("並び方", selection: $presetMode) { Text("よく使う順").tag(FoodPresetRanking.Mode.frequent); Text("この区分で使う順").tag(FoodPresetRanking.Mode.mealTime) }
          NavigationLink("並びを固定・変更") { FoodPresetOrderPage(catalog: model.state.catalog, meals: rankingMeals, slot: slot, mode: presetMode).toolbar(.visible,for:.navigationBar) }
          NavigationLink("食事の記録設定") { RecordingPreferencesPage().toolbar(.visible,for:.navigationBar) }
          NavigationLink("食品成分表から登録") {ReferenceFoodPage(model:model).toolbar(.visible,for:.navigationBar)}
          Button("成分表示から登録") { labelOCR=true }
          Button("プリセットを編集") { catalog=true }
        } label: { Image(systemName: "slider.horizontal.3").frame(width: 32, height: 32) }.accessibilityLabel("検索と記録の設定")
      }.padding(12).background(pine.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
      if !fixedPresetOrder.isEmpty { Text("固定した並びを優先しています").font(.caption).foregroundStyle(.secondary) }
      let presets = FoodPresetRanking.order(model.state.catalog.visiblePresets(query: query, categoryID: category, aliases: searchAliases), meals: rankingMeals, slot: slot, mode: presetMode, fixedOrder: fixedPresetOrder)
      if !query.isEmpty {
        Text("\(presets.count)件のプリセット · \(model.state.catalog.categories.first(where:{$0.id==category})?.name ?? "すべて")")
          .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("food-preset-search-count")
      }
      if presets.isEmpty {
        Card {
          if model.state.catalog.presets.isEmpty {
            Label("プリセットはまだありません", systemImage: "tray").foregroundStyle(.secondary)
            Text("よく食べる食品や組合せを登録すると、次から押すだけで記録できます。").font(.caption).foregroundStyle(.secondary)
            Button("食品・プリセットを登録") { catalog = true }.buttonStyle(.bordered)
          } else {
            Label("該当するプリセットがありません", systemImage: "magnifyingglass").foregroundStyle(.secondary)
            Text("検索語やカテゴリーを変えてください。非表示の設定は編集から確認できます。").font(.caption).foregroundStyle(.secondary)
            if category != nil {
              Button("すべてのカテゴリーで探す") { category=nil; searchFocused=false }.buttonStyle(.bordered)
            }
          }
        }
      }
      ForEach(presets) { p in
        Button {
          refreshImplicitDate()
          if !LargePresetConfirmations.contains(p.id, p.revision), p.components.contains(where: { UnusualNumericEntry.needsConfirmation(.quantity, value: $0.factor, baseline: 1) }) {
            unusualPreset = (p.id, day, slot)
          } else { withAnimation(Motion.animation(reduceMotion: motion.reduced)) { model.add(p.id, date: day, slot: slot) } }
        } label: {
          HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
              Text(p.name).font(.headline).foregroundStyle(.primary)
              let items = (try? model.state.catalog.snapshot(p.id)) ?? []
              let total = FoodTotal(items: items)
              HStack {
                MockFigure(value: foodNumber(total.displayValue(for:.kcal)), unit: "kcal", size: 20)
                if (total.missing[.kcal] ?? 0) > 0 { Text("一部不明").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text(items.count == 1 ? "\(foodNumber(items[0].quantity))\(items[0].unit)（標準）" : "1食（標準）").font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Image(systemName: "plus.circle").font(.title2).foregroundStyle(pine)
          }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(Rectangle())
        }.buttonStyle(HubPressStyle()).accessibilityLabel("\(p.name)を追加")
      }
      Button { refreshImplicitDate(); analysis=true } label: {
        HubSettingsRow(title: "写真・文章から記録", subtitle: "食べたものと量を確認して登録します", symbol: "sparkles")
      }.buttonStyle(.plain).padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16)).accessibilityLabel("写真・文章から記録")
      // 大皿の「食事中」は食事画面に出す。続き（残りの撮影）を忘れないため。3時間たったら知らせる（DESIGN 2.2、10/4）。
      if !preview, let plate = SharedPlateModel.live.session {
        Button { plateOpen = true } label: {
          HubSettingsRow(title: plate.after == nil ? "食事中（大皿）· 残りを撮る" : "食事中（大皿）· 解析して記録",
                         subtitle: "\(mockDay(plate.date)) · \(plate.slot)" + (SharedPlateModel.live.reminder ? " · 3時間たちました。食べた量を選んでください" : ""), symbol: "fork.knife.circle")
        }.buttonStyle(.plain).padding(16).background(pine.opacity(0.08), in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("food-plate-in-progress")
      }
      if !model.message.isEmpty && (model.lastUndo == nil || model.message != model.undoText) { Text(model.message).font(.caption).foregroundStyle(model.message == model.undoText || model.lastUndo == nil ? Color.secondary : Color.red).accessibilityIdentifier("food-feedback") }
      if let planning {
        DisclosureGroup("目標とサプリ") {
          PlanningDayCard(model:planning,date:day,consumed:planningConsumed(total:foodTotal))
          NavigationLink("カテゴリー内のサプリ・自動計上") { SupplementPage(model:planning,date:day) }
        }.font(.subheadline)
      }
      HubMockCard {
        HStack { Text("摂取合計").font(.subheadline); Spacer(); MockFigure(value: foodNumber(total.displayValue(for:.kcal)), unit: "kcal", size: 24) }
        if total.missing.values.contains(where: { $0 > 0 }) { HubUnknownNutrientsHelp() }
      }
      if let hydration {HydrationCard(model:hydration,date:day)}
      HStack {
        Text("この日の記録").font(.title3.bold())
        Spacer()
        NavigationLink("履歴") { FoodHistoryPage(model: model, initialDate: date, syncing: syncing, planning: planning) }
      }
      ForEach(FoodRules.slots, id: \.self) { section in
        let meals = (projection?.meals ?? model.state.confirmed).filter {
          !$0.removed && $0.date == day && $0.slot == section
        }
        if !meals.isEmpty {
          Text(section).font(.subheadline.bold()).foregroundStyle(.secondary)
          ForEach(meals) { meal in
            Card {
              FoodMealContents(meal: meal)
              if let status=model.saveStatus(meal.id) {Text(status).font(.caption).foregroundStyle(.secondary)}
              HStack {
                Button("量・日付を変更") { editing = meal }
                Spacer()
                Button("取消", role: .destructive) { removing = meal }
              }.font(.subheadline).disabled(model.editingBlocked(meal.id))
            }
          }
        }
      }
      if (projection?.meals ?? model.state.confirmed).filter({ !$0.removed && $0.date == day }).isEmpty {
        Card { Text("この日の食事はありません").foregroundStyle(.secondary) }
      }
      if let projection {
        let notices = projection.pending.filter {$0.meal.removed || $0.undoRequested || projection.reviewIDs.contains($0.id)}
        if !notices.isEmpty { Text("同期待ち・要確認").font(.title3.bold()) }
        ForEach(notices) { op in
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
    }.modifier(FoodUndoOverlay(model: model))
    .toolbar {
      ToolbarItemGroup(placement:.keyboard) {
        if searchFocused { Spacer(); Button("検索") { searchFocused=false } }
      }
    }
    .sheet(isPresented:$labelOCR){NavigationStack{FoodLabelPage(model:model,preview:preview)}}
    .onAppear { refreshImplicitDate(); fixedPresetOrder=PresetDisplayPreferences.fixedOrder; searchAliases=FoodSearchPreferences.aliases; rankingMeals=model.state.confirmed }
    .onChange(of: catalog) { _, open in if !open { searchAliases=FoodSearchPreferences.aliases } }
    .onChange(of: presetMode) { _, mode in PresetDisplayPreferences.mode=mode }
    .onChange(of: scenePhase) { _, phase in if phase == .active { refreshImplicitDate(); rankingMeals=model.state.confirmed } }
    .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in refreshImplicitDate() }
    .alert("基準量より大きい食事です", isPresented: Binding(get: { unusualPreset != nil }, set: { if !$0 { unusualPreset=nil } })) {
      Button("この量で記録") { if let proposed=unusualPreset { if let p=model.state.catalog.presets.first(where: { $0.id == proposed.0 }) { LargePresetConfirmations.insert(p.id, p.revision) }; model.add(proposed.0, date: proposed.1, slot: proposed.2) }; unusualPreset=nil }
      Button("記録しない", role: .cancel) { unusualPreset=nil }
    } message: { Text("食品の基準量の5倍以上の品目があります。意図した量であれば、そのまま記録できます。") }
    .animation(Motion.animation(reduceMotion: motion.reduced), value: model.state.confirmed.filter { !$0.removed }.map(\.id))
    .sheet(isPresented: $choosingDate) {
      NavigationStack {
        DatePicker("記録する日", selection: Binding(get: { date }, set: { dateChosen=true; chosenOnDay=RecordingPreferences.day(); date=$0 }), displayedComponents: .date)
          .datePickerStyle(.graphical).environment(\.timeZone, FoodDates.calendar.timeZone).padding().navigationTitle("記録する日")
          .navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.confirmationAction) { Button("完了") { choosingDate=false } } }
      }.presentationDetents([.medium,.large])
    }
    .sheet(isPresented: $plateOpen) {
      if let plate = SharedPlateModel.live.session {
        NavigationStack {
          SharedPlatePage(date: plate.date, slot: plate.slot, analyze: plateAnalyzer, preview: false) { draft, d, mealSlot, identity in
            try model.confirm(draft, date: d, slot: mealSlot, identity: identity); plateOpen = false
          }
        }
      }
    }
    .sheet(isPresented: $analysis) {
      NavigationStack {
        FoodAnalysisPage(date: day, slot: slot, analyze: analyze, initialNote: initialAnalysisNote, plateAnalyze: plateAnalyzer, platePreview: preview, plateSave: { draft, day, mealSlot, identity in try model.confirm(draft, date: day, slot: mealSlot, identity: identity) })
        { draft in
          try model.confirm(draft, date: day, slot: slot)
        }
      }
    }.sheet(item: $editing) { meal in
      NavigationStack {
        FoodMealEditor(meal: meal, catalog: model.state.catalog) { factor, d, s in
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
    }.buttonStyle(.plain).accessibilityAddTraits(category == id ? .isSelected : [])
  }
  private func refreshImplicitDate() {
    // 別の日を選んだまま記録日が変わったら（翌朝に開いたなど）、選択を解いて今日へ戻す（10/4）。
    if dateChosen, let chosenOnDay, chosenOnDay != RecordingPreferences.day() { dateChosen=false; self.chosenOnDay=nil; slotChosen=false }
    guard implicitDate && !dateChosen && !analysis && !catalog && editing == nil && removing == nil && unusualPreset == nil else { return }
    date = RecordingPreferences.day()
    if !slotChosen { slot = FoodHubPage.defaultSlot() }
  }
  /// 時刻から区分の初期値を決める：〜4:00 間食（夜食）、〜10:30 朝食、〜15:00 昼食、〜17:00 間食、それ以降 夕食。
  static func defaultSlot(at now: Date = .now) -> String {
    let c = FoodDates.calendar.dateComponents([.hour, .minute], from: now), m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    switch m { case ..<240: return "間食"; case ..<630: return "朝食"; case ..<900: return "昼食"; case ..<1020: return "間食"; default: return "夕食" }
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
          Text("\(i.nutrients.kcal.map(foodNumber) ?? "—") kcal").font(.subheadline.monospacedDigit())
        }.motionReveal(order: order)
      }
      Text("\(mockDay(meal.date)) · \(meal.slot)").font(.caption2).foregroundStyle(
        .secondary)
    }
  }
}
struct FoodMealEditor: View {
  private var motion = MotionPolicy()
  let meal: FoodMeal, save: (Double, String, String) -> Void
  let catalog: FoodCatalog?
  @Environment(\.dismiss) private var dismiss
  @State private var factor = "1"
  @State private var date: Date
  @State private var slot: String
  @State private var error = ""
  @State private var increasing = true
  @State private var unusual = false
  @State private var proposed: (Double, String, String)?
  init(meal: FoodMeal, catalog: FoodCatalog? = nil, save: @escaping (Double, String, String) -> Void) {
    self.meal = meal
    self.save = save
    self.catalog = catalog
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
            if UnusualNumericEntry.unusualMealQuantity(meal, factor: n, catalog: catalog) {
              proposed = (n, FoodDates.text(date), slot); unusual = true
            } else { save(n, FoodDates.text(date), slot); dismiss() }
          } catch { self.error = error.localizedDescription }
        }
      }
    }.alert("量がいつもより大きくなっています", isPresented: $unusual) {
      Button("この量で保存") { if let proposed { save(proposed.0, proposed.1, proposed.2); dismiss() }; proposed=nil }
      Button("入力に戻る", role: .cancel) { proposed=nil }
    } message: { Text("食品の基準量の5倍以上です。基準量がない食品は、記録時の量と比べています。意図した量であれば、そのまま保存できます。") }
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
  @State private var expandedSlots = Set(FoodRules.slots)
  @State private var pickingDate = false
  private var motion = MotionPolicy()
  var planning: PlanningScreenModel? = nil
  init(model: FoodScreenModel, initialDate: Date, syncing: Bool = false, planning: PlanningScreenModel? = nil) {
    self.syncing = syncing; self.planning = planning
    self.model = model
    _date = State(initialValue: initialDate)
  }
  var body: some View {
    HubMockPage(title: "食事履歴", showNavigation: true) {
      // 「‹ 10月4日（日） ›」で1日ずつ動かし、日付を押すとカレンダーを開く（10/4）。
      HStack(spacing: 8) {
        Button { date = FoodDates.calendar.date(byAdding: .day, value: -1, to: date)! } label: { Image(systemName: "chevron.left").frame(width: 32, height: 44) }.accessibilityLabel("前の日")
        Button { pickingDate.toggle() } label: { HStack(spacing: 6) { Text(mockDay(date)).font(.headline); Image(systemName: "calendar").font(.subheadline) }.foregroundStyle(.primary) }.accessibilityLabel("日付を選ぶ \(mockDay(date))")
        Spacer()
        Button { date = FoodDates.calendar.date(byAdding: .day, value: 1, to: date)! } label: { Image(systemName: "chevron.right").frame(width: 32, height: 44) }.accessibilityLabel("次の日")
      }
      if pickingDate {
        DatePicker("日付", selection: Binding(get: { date }, set: { date = $0; pickingDate = false }), displayedComponents: .date).datePickerStyle(.graphical).environment(\.timeZone, FoodDates.calendar.timeZone)
      }
      let projection = try? FoodDayPresentation(date:FoodDates.text(date),snapshot:model.state)
      let visibleMeals = projection?.meals ?? model.state.confirmed.filter { !$0.removed && $0.date == FoodDates.text(date) }
      HubMockCard {
        // 食事画面・ホームと同じく、予定から自動計上するサプリも合計に含める（10/4）。
        let foodTotal = projection?.localTotal ?? FoodTotal.day(FoodDates.text(date), meals: model.state.confirmed)
        let withSupplements = (try? planning?.totalWithSupplements(foodTotal, date: FoodDates.text(date))) ?? foodTotal
        let supplementKcal = (withSupplements.known[.kcal] ?? 0) - (foodTotal.known[.kcal] ?? 0)
        HStack { Text("摂取合計"); Spacer(); MockFigure(value: foodNumber(withSupplements.known[.kcal]), unit: "kcal", size: 34) }
        if supplementKcal > 0.05 { Text("うちサプリ \(foodNumber(supplementKcal)) kcal").font(.caption).foregroundStyle(.secondary) }
        if FoodTotal(items:visibleMeals.flatMap(\.items)).missing.values.contains(where:{$0>0}) { HubUnknownNutrientsHelp() }
        HStack { ForEach(FoodRules.slots, id: \.self) { slot in
          VStack(spacing: 4) { Text(slot).font(.caption).foregroundStyle(.secondary); Text(hubFoodEnergy(visibleMeals.filter { $0.slot == slot }.flatMap(\.items))+" kcal").font(.caption.bold()) }.frame(maxWidth: .infinity)
        } }
      }
      if syncing { MotionSkeleton() }
      ForEach(FoodRules.slots, id: \.self) { slot in
        let meals = visibleMeals.filter { $0.slot == slot }
        if !meals.isEmpty {
          DisclosureGroup(isExpanded:Binding(get:{expandedSlots.contains(slot)},set:{ if $0 { expandedSlots.insert(slot) } else { expandedSlots.remove(slot) } })) {
          ForEach(meals) { meal in HubMockCard {
            // 行を押すと量・日付・区分の編集を開く（「…」のメニューも残す）。
            VStack(alignment:.leading,spacing:6) {
              Text(meal.items.map(\.name).joined(separator:"・")).font(.subheadline.bold()).accessibilityIdentifier("food-history-meal-name")
              HStack(alignment:.firstTextBaseline) {
                MockFigure(value:meal.items.allSatisfy { $0.nutrients.kcal == nil } ? "—" : foodNumber(FoodTotal(items:meal.items).known[.kcal]),unit:"kcal",size:18)
                HubMealMacroLine(items:meal.items)
              }
              if let status=model.saveStatus(meal.id) {Text(status).font(.caption).foregroundStyle(.secondary)}
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
              .onTapGesture { if !model.editingBlocked(meal.id) { editing=meal } }
            MotionRowMenu(title: meal.items.map(\.name).joined(separator: "・")) {
              MotionMenuAction(title: "量・日付を変更") { editing=meal }
              MotionMenuAction(title: "取消", role: .destructive) { removing=meal }
            }.disabled(model.editingBlocked(meal.id))
          }.transition(.move(edge: .trailing).combined(with: .opacity)) }
          } label: {
            HStack { Circle().fill(pine.opacity(0.6)).frame(width: 9,height: 9); Text(slot).font(.headline); Text(hubFoodEnergy(meals.flatMap(\.items))+" kcal").font(.subheadline) }
          }.accessibilityIdentifier("food-history-"+slot)
        }
      }
      let review = model.state.pending.filter { projection?.reviewIDs.contains($0.id) == true }
      if !review.isEmpty {
        Text("確認待ち · 集計外").font(.headline)
        ForEach(review) { op in HubMockCard { FoodMealContents(meal: op.meal); Text(op.error ?? "内容を確認してください").font(.caption).foregroundStyle(.orange) } }
      }
      if visibleMeals.isEmpty {
        ContentUnavailableView("記録がありません", systemImage: "calendar")
      }
    }.modifier(FoodUndoOverlay(model: model))
    .animation(Motion.animation(reduceMotion: motion.reduced), value: model.state.confirmed.filter { !$0.removed }.map(\.id))
      .sheet(item: $editing) { meal in NavigationStack { FoodMealEditor(meal: meal, catalog: model.state.catalog) { factor, date, slot in model.edit(meal, factor: factor, date: date, slot: slot) } }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
      .confirmationDialog(removing.map { "\(mockDay($0.date))の「\($0.items.map(\.name).joined(separator: "・"))」を取り消しますか" } ?? "この食事を取り消しますか", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing=nil } }), titleVisibility: .visible) {
        Button("この食事を取り消す", role: .destructive) { if let removing { model.remove(removing) }; removing=nil }
      } message: { Text("取り消した直後なら「元に戻す」で戻せます。") }
  }
}
private struct FoodCatalogRemoval: Identifiable {
  let kind: FoodCatalogEntry.Kind, targetID: String, name: String
  var id: String {kind.rawValue+":"+targetID}
}

struct FoodCatalogPage: View {
  @Bindable var model: FoodScreenModel
  @Environment(\.dismiss) private var dismiss
  @State private var removal: FoodCatalogRemoval?
  @State private var newPreset = false
  @State private var newFood = false
  @State private var versionEditing: FoodVersion?
  @State private var newCategory = false
  @State private var categoryName = ""
  @State private var editing: FoodPreset?
  @State private var error = ""
  var body: some View {
    List {
      Section("登録した食品") {
        ForEach(model.state.catalog.availableVersions) { v in
          HStack {
          Button { versionEditing = v } label: {
          VStack(alignment: .leading) {
            Text(v.name).font(.headline)
            Text("\(foodNumber(v.quantity))\(v.unit) · \(v.preparation)").font(
              .caption
            ).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain)
          Spacer()
          Menu {
            Button("削除",role:.destructive) { removal=FoodCatalogRemoval(kind:.food,targetID:v.foodID,name:v.name) }
          } label: {Image(systemName:"ellipsis").frame(width:44,height:44)}
            .accessibilityLabel(v.name+"の食品の操作").accessibilityIdentifier("catalog-food-actions-"+v.id)
          }
        }
        Button("食品を追加") { newFood = true }
      }
      Section("プリセット") {
        ForEach(model.state.catalog.presets.filter {!model.state.catalog.isDeleted($0)}) { p in
          HStack {
          Button {
            editing = p
          } label: {
            HStack {
              Text(p.name)
              Spacer()
              Text(p.archived ? "非表示" : "").foregroundStyle(.secondary)
            }
          }.accessibilityLabel(p.name + "のプリセットを編集")
          Menu {
            Button("削除",role:.destructive) {removal=FoodCatalogRemoval(kind:.preset,targetID:p.id,name:p.name)}
          } label: {Image(systemName:"ellipsis").frame(width:44,height:44)}
            .accessibilityLabel(p.name+"のプリセットの操作").accessibilityIdentifier("catalog-preset-actions-"+p.id)
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
      let deleted=model.state.catalog.entries.filter(\.deleted)
      if !deleted.isEmpty {
        Section {
          DisclosureGroup("削除済み（\(deleted.count)件）") {
            ForEach(deleted) {entry in
              HStack {
                Text(deletedName(entry));Spacer()
                Button("復元") {setDeleted(entry.kind,targetID:entry.targetID,deleted:false)}
                  .accessibilityIdentifier("catalog-restore-"+entry.id)
              }
            }
            Text("過去の食事を保つための情報は残しています。復元すると一覧から再び使えます。")
              .font(.caption).foregroundStyle(.secondary)
          }.accessibilityIdentifier("catalog-deleted")
        }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.alert("\(removal?.name ?? "項目")を削除しますか",isPresented:Binding(get:{removal != nil},set:{if !$0 {removal=nil}})) {
      Button("削除",role:.destructive) {if let target=removal {setDeleted(target.kind,targetID:target.targetID,deleted:true)};removal=nil}
      Button("やめる",role:.cancel) {removal=nil}
    } message: {
      Text(removal?.kind == .food ? "通常の食品一覧から削除し、この食品を使うプリセットも外します。過去の食事は保持します。削除済み一覧から復元できます。" : "通常のプリセット一覧から削除します。過去の食事は保持します。削除済み一覧から復元できます。")
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
  private func setDeleted(_ kind: FoodCatalogEntry.Kind,targetID:String,deleted:Bool) {
    do {var catalog=model.state.catalog;try catalog.setDeleted(kind,targetID:targetID,deleted:deleted);try model.save(catalog);error=""}
    catch {self.error=error.localizedDescription}
  }
  private func deletedName(_ entry: FoodCatalogEntry) -> String {
    let catalog=model.state.catalog
    if entry.kind == .preset {return catalog.presets.first {$0.id==entry.targetID}?.name ?? "プリセット"}
    return catalog.versions.filter {$0.foodID==entry.targetID}.max(by:{$0.revision<$1.revision})?.name ?? "食品"
  }

}
struct FoodVersionEditor: View {
  let save: (FoodVersion) throws -> Void
  let prior: FoodVersion?
  let nextRevision: Int
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var quantity = ""
  @State private var quantityFromPrevious = true
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
    _quantity = State(initialValue: prior.map { String($0.quantity) } ?? NumericHistory.quantity(unit: "個"))
    _quantityFromPrevious = State(initialValue: prior == nil)
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
        LabeledContent("基準量") { TextField("基準量", text: Binding(get: { quantity }, set: { quantity=$0; quantityFromPrevious=false })).motionFieldError(error).keyboardType(.decimalPad) }
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
    }.onChange(of: unit) { _, newUnit in if prior == nil && quantityFromPrevious { quantity=NumericHistory.quantity(unit: newUnit) } }
      .navigationTitle(prior == nil ? "食品を追加" : "食品の内容を更新").navigationBarTitleDisplayMode(.inline)
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
              NumericHistory.rememberQuantity(q, unit: unit)
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
  @State private var aliases: String
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
    _aliases = State(initialValue: preset.map { FoodSearchPreferences.aliases[$0.id]?.joined(separator: "、") ?? "" } ?? "")
  }
  var body: some View {
    Form {
      Section("プリセット") {
        TextField("名前", text: $name)
        TextField("検索用の読み・略称", text: $aliases, axis: .vertical)
        Text("読みや略称は、読点で区切ってこの端末に保存します。").font(.caption).foregroundStyle(.secondary)
        Picker("カテゴリー", selection: $category) {
          Text("分類なし").tag("")
          ForEach(catalog.categories) { Text($0.name).tag($0.id) }
        }
        Toggle("一覧から非表示", isOn: $archived)
      }
      Section("組み合わせる食品") {
        ForEach(catalog.availableVersions) { v in
          VStack(alignment: .leading) {
            Toggle(
              "\(v.name) · \(foodNumber(v.quantity))\(v.unit)",
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
            let aliasData=try FoodSearchPreferences.prepared(aliases, for: p.id)
            try save(p)
            FoodSearchPreferences.save(aliasData)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }
      }
    }
  }
}

private struct FoodUndoBottomInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}
extension EnvironmentValues {
  var foodUndoBottomInset: CGFloat {
    get { self[FoodUndoBottomInsetKey.self] }
    set { self[FoodUndoBottomInsetKey.self] = newValue }
  }
}

struct FoodUndoOverlay: ViewModifier {
  @Environment(\.foodUndoBottomInset) private var bottomInset
  @Bindable var model: FoodScreenModel
  private var motion = MotionPolicy()
  func body(content: Content) -> some View {
    content.safeAreaInset(edge: .bottom, spacing: 0) {
      if let change=model.lastUndo, change.available() {
        HStack {
          Text(model.undoText).font(.subheadline).lineLimit(2)
          Spacer()
          Button("元に戻す", systemImage: "arrow.uturn.backward") {
            withAnimation(Motion.animation(reduceMotion: motion.reduced)) { model.undo() }
          }.buttonStyle(.bordered).accessibilityIdentifier("food-undo")
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 12).padding(.bottom, bottomInset)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .task(id: change.operationID) {
            do { try await Task.sleep(for: .seconds(max(0, change.expiresAt.timeIntervalSinceNow))) } catch { return }
            model.expireUndo(change.operationID)
          }
      }
    }.animation(Motion.animation(reduceMotion: motion.reduced), value: model.lastUndo?.operationID)
  }
}

/// 倍率の大きいプリセット（例：アーモンド10粒）は、同じ版を一度確認したら次から聞かない（10/4：定番なのに毎回2タップになっていた）。
/// プリセットを改訂すると版が変わるので、もう一度確認する。合成表示では端末に残さない。
@MainActor enum LargePresetConfirmations {
  private static var previewMemory = Set<String>()
  private static var preview: Bool { ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--p") && $0.hasSuffix("-preview") } }
  private static let key = "food-large-preset-confirmed"
  static func contains(_ id: String, _ revision: Int) -> Bool {
    preview ? previewMemory.contains("\(id)#\(revision)") : (UserDefaults.standard.stringArray(forKey: key) ?? []).contains("\(id)#\(revision)")
  }
  static func insert(_ id: String, _ revision: Int) {
    if preview { previewMemory.insert("\(id)#\(revision)"); return }
    var list = UserDefaults.standard.stringArray(forKey: key) ?? []; list.append("\(id)#\(revision)"); UserDefaults.standard.set(Array(list.suffix(200)), forKey: key)
  }
}
