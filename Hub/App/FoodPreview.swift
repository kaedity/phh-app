#if DEBUG
  import SwiftUI
  import PHHHubCore

  struct FoodPreviewRoot: View {
    @State private var model: FoodScreenModel
    init() {
      let empty = ProcessInfo.processInfo.arguments.contains("--empty")
      if ProcessInfo.processInfo.arguments.contains("--common-outbox") {
        let hub=try! HubStore(owner:"synthetic@example.test")
        let page=try! JSONDecoder().decode(Delta.self,from:Data(#"{"schema_version":1,"environment":"PHH_PRODUCTION","generation":1,"food_contract":1,"catalog_entry_contract":1,"snapshot_revision":0,"changes":[],"next_cursor":0,"has_more":false}"#.utf8))
        try! hub.apply(page);let common=FoodHubStore(hub:hub);try! common.saveCatalog(FoodPreviewData.catalog)
        _model=State(initialValue:try! FoodScreenModel(store:common,onSaved:{}));return
      }
      var catalog = empty ? try! FoodCatalog() : FoodPreviewData.catalog
      if ProcessInfo.processInfo.arguments.contains("--duplicate-preset-search") {
        try! catalog.save(FoodPreset(name:"架空の確認食品",components:[.init(versionID:FoodPreviewData.bread.id)],archived:true))
        try! catalog.save(FoodPreset(name:"架空の確認食品",components:[.init(versionID:FoodPreviewData.bread.id)]))
      }
      if ProcessInfo.processInfo.arguments.contains("--large-preset") {
        try! catalog.save(FoodPreset(name: "架空の5倍", components: [.init(versionID: FoodPreviewData.bread.id, factor: 5)]))
      }
      let state = try! FoodLocalState(
        catalog: catalog,
        confirmed: empty ? [] : FoodPreviewData.meals)
      _model = State(initialValue: FoodScreenModel(store: try! FoodLocalStore(initial: state)))
    }
    var body: some View {
      NavigationStack {
        FoodHubPage(
          model: model, date: FoodDates.date("2026-10-02"),
          analyze: { jpegs, note in
            if ProcessInfo.processInfo.arguments.contains("--multi-photo-check") {
              guard jpegs.count==2, note.contains("スープは半分") else { throw FoodFailure.invalidValue }
            }
            var draft = try FoodDraft.fromAnalysisJSON(FoodPreviewData.analysis)
            if note.contains("再解析前の確認画面") {
              if ProcessInfo.processInfo.arguments.contains("--reanalysis-fail") { throw FoodFailure.invalidValue }
              if ProcessInfo.processInfo.arguments.contains("--reanalysis-check") {
                guard note.contains("\"answer\":\"半分\"") else { throw FoodFailure.invalidValue }
                draft.items = try draft.items.map { try $0.scaled(0.5) }
              }
            }
            if ProcessInfo.processInfo.arguments.contains("--no-questions") { draft.questions = [] }
            return draft
          },
          preview: true, initialAnalysisNote: "架空のチキンプレート1皿")
      }.tint(pine)
    }
  }
  enum FoodPreviewData {
    static let category = try! FoodCategory(name: "朝の定番")
    static let bread = try! FoodVersion(
      name: "全粒粉パン", unit: "個", source: "商品表示",
      nutrients: .init(kcal: 100, protein: 10, fat: 0, carbohydrate: 15))
    static let egg = try! FoodVersion(
      name: "ゆで卵", unit: "個", preparation: "加熱済み", source: "成分表",
      nutrients: .init(kcal: 75, protein: 6, fat: 5, carbohydrate: 0.3))
    static let soup = try! FoodVersion(
      name: "野菜スープ", unit: "杯", source: "本人",
      nutrients: .init(kcal: nil, protein: nil, fat: nil, carbohydrate: nil))
    static let preset = try! FoodPreset(
      name: "いつもの朝食", categoryID: category.id,
      components: [.init(versionID: bread.id), .init(versionID: egg.id)])
    static let catalog = try! FoodCatalog(
      versions: [bread, egg, soup], categories: [category],
      presets: [
        preset, .init(name: "全粒粉パン", components: [.init(versionID: bread.id)]),
        .init(name: "野菜スープ", components: [.init(versionID: soup.id)]),
      ])
    static let meals = try! [
      FoodMeal(
        date: "2026-10-02", slot: "朝食", items: catalog.snapshot(preset.id), presetID: preset.id,
        presetRevision: 1),
      FoodMeal(
        date: "2026-10-02", slot: "昼食",
        items: [
          .init(
            name: soup.name, quantity: 1, unit: soup.unit, source: soup.source, versionID: soup.id,
            nutrients: soup.nutrients)
        ]),
    ]
    static let analysis = Data(
      #"{"items":[{"name":"架空のチキンプレート","quantity":1,"unit":"皿","kcal":420,"protein_g":30,"fat_g":12,"carbohydrate_g":48,"source":"推定","confidence":"中"}],"uncertain_points":["ソースの量は推定です。"],"questions":["食べた量は1皿ですか？"]}"#
        .utf8)
  }
  #Preview("架空の食事") { FoodPreviewRoot() }
#endif
