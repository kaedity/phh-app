import PHHHubCore
import SwiftUI

/// 食品成分表はアプリに同梱した公式データから検索します。
struct ReferenceFoodPage: View {
  @Bindable var model: FoodScreenModel
  @Environment(\.dismiss) private var dismiss
  @State private var database: ReferenceFoodDatabase?
  @State private var query: String
  @State private var groupCode: String?
  @State private var selected: ReferenceFood?
  @State private var error = ""
  @State private var retry = 0

  init(model: FoodScreenModel, database: ReferenceFoodDatabase? = nil, initialQuery: String = "") {
    self.model = model
    _database = State(initialValue: database)
    _query = State(initialValue: initialQuery)
  }

  var body: some View {
    List {
      if let database {
        Section {
          Text(database.title).font(.subheadline)
          Text("可食部100g当たり · \(database.revisionDate)更新")
            .font(.caption).foregroundStyle(.secondary)
          Picker("食品群", selection: $groupCode) {
            Text("すべて").tag(nil as String?)
            ForEach(database.groups, id: \.code) { group in
              Text(group.name).tag(group.code as String?)
            }
          }.accessibilityIdentifier("reference-food-group")
        }
        let result = database.search(query: query, groupCode: groupCode)
        Section {
          if result.foods.isEmpty {
            Text("該当する食品がありません。食品名・食品番号・食品群を変えて検索してください。")
              .foregroundStyle(.secondary)
          }
          ForEach(result.foods) { food in
            Button { selected = food } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(food.name).foregroundStyle(.primary)
                Text("\(food.code) · \(food.group) · \(food.kcal) kcal / 100g")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }.accessibilityIdentifier("reference-food-row-\(food.code)")
          }
        } header: {
          Text(result.omitted > 0 ? "\(result.total)件 · 先頭\(result.foods.count)件を表示" : "\(result.total)件")
        } footer: {
          if result.omitted > 0 { Text("食品名や食品群で絞り込むと、続きの食品を表示できます。") }
        }
        Section {
          Text(database.attribution).font(.caption).foregroundStyle(.secondary)
          if let url = URL(string: database.sourcePage) {
            Link("文部科学省の食品成分表", destination: url)
          }
        }
      } else if error.isEmpty {
        Section { ProgressView("食品成分表を読み込んでいます") }
      } else {
        Section {
          Text(error).foregroundStyle(.red).accessibilityIdentifier("reference-food-error")
          Button("読み込みを再試行") { retry += 1 }
        }
      }
    }
    .navigationTitle("食品成分表から登録")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $query, prompt: "食品名・食品番号")
    .accessibilityIdentifier("reference-food-list")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("閉じる") { dismiss() }.accessibilityIdentifier("reference-food-close")
      }
    }
    .sheet(item: $selected) { food in
      if let database {
        NavigationStack {
          ReferenceFoodConfirmationPage(model: model, database: database, food: food) {
            selected = nil
            dismiss()
          }
        }
      }
    }
    .task(id: retry) {
      guard database == nil else { return }
      error = ""
      do {
        let worker = Task.detached(priority: .userInitiated) {
          try ReferenceFoodDatabase.bundled()
        }
        let next = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        database = next
      } catch is CancellationError {
      } catch { self.error = error.localizedDescription }
    }
  }
}

private struct ReferenceFoodConfirmationPage: View {
  @Bindable var model: FoodScreenModel
  let database: ReferenceFoodDatabase
  let food: ReferenceFood
  let didSave: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var presetName: String
  @State private var quantity = "100"
  @State private var categoryID: String?
  @State private var confirmed = false
  @State private var saving = false
  @State private var error = ""
  @State private var confirmBack = false
  @FocusState private var focusedField: Field?
  private enum Field: Hashable { case name, quantity }

  private var hasInput: Bool {
    presetName != food.name || quantity != "100" || categoryID != nil || confirmed
  }

  init(
    model: FoodScreenModel, database: ReferenceFoodDatabase, food: ReferenceFood,
    didSave: @escaping () -> Void
  ) {
    self.model = model; self.database = database; self.food = food; self.didSave = didSave
    _presetName = State(initialValue: food.name)
  }

  var body: some View {
    Form {
      Section("食品を確認") {
        Text(food.name).font(.headline).accessibilityIdentifier("reference-food-selected-name")
        Text("食品番号 \(food.code) · \(food.group)").font(.caption).foregroundStyle(.secondary)
        Text("食品名の生・ゆで・焼きなどの状態と、実際に使う食品が一致するか確認してください。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("可食部100g当たりの成分値") {
        ForEach(FoodNutrient.allCases, id: \.self) { key in
          let cell = food.cell(key)
          LabeledContent(nutrientName(key)) {
            VStack(alignment: .trailing, spacing: 3) {
              Text(cell.raw.isEmpty ? "不明" : cell.raw + (key == .kcal ? " kcal" : " g"))
                .accessibilityIdentifier("reference-food-\(key.rawValue)")
              if cell.kind != .numeric {
                Text(cell.explanation).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        Text("括弧付きの数値は推定値です。Tr・－は数値不明のまま登録します。成分表の0には丸め・検出限界を含みます。")
          .font(.caption).foregroundStyle(.secondary)
        if !food.note.isEmpty {
          DisclosureGroup("成分表の備考") { Text(food.note).font(.caption).textSelection(.enabled) }
        }
      }
      Section("プリセットの量") {
        LabeledContent("プリセット名") {
          TextField("プリセット名", text: $presetName)
            .focused($focusedField, equals: .name).submitLabel(.next)
            .onSubmit { focusedField = .quantity }
            .accessibilityIdentifier("reference-food-preset-name")
        }
        LabeledContent("既定量（g）") {
          TextField("既定量", text: $quantity).keyboardType(.decimalPad)
            .focused($focusedField, equals: .quantity)
            .accessibilityIdentifier("reference-food-quantity")
        }
        Text("食品の基準は100gのまま保存し、プリセットではここで指定した可食部の量を使います。")
          .font(.caption).foregroundStyle(.secondary)
        Picker("カテゴリー", selection: $categoryID) {
          Text("指定なし").tag(nil as String?)
          ForEach(model.state.catalog.categories.filter { !$0.archived }) { category in
            Text(category.name).tag(category.id as String?)
          }
        }.accessibilityIdentifier("reference-food-category")
      }.disabled(saving)
      Section("出典") {
        Text(database.attribution).font(.caption)
        Text("\(database.publisher) · \(database.revisionDate)修正版").font(.caption)
          .foregroundStyle(.secondary)
        if let url = URL(string: database.sourcePage) {
          Link("公式の成分表を確認", destination: url)
        }
      }
      Section {
        Toggle("食品・調理状態と100gの成分値を確認しました", isOn: $confirmed)
          .disabled(saving).accessibilityIdentifier("reference-food-reviewed")
        Button(action: register) { MotionSaveLabel(title: "確認してプリセット登録", busy: saving) }
          .disabled(saving || !confirmed).accessibilityIdentifier("reference-food-save")
      }
      if !error.isEmpty {
        Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("reference-food-save-error") }
      }
    }
    .navigationTitle("成分表の食品を確認")
    .navigationBarTitleDisplayMode(.inline)
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("戻る") { if hasInput { confirmBack = true } else { dismiss() } }
          .disabled(saving).accessibilityIdentifier("reference-food-back")
      }
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("入力を終える") { focusedField = nil }
      }
    }
    .interactiveDismissDisabled(hasInput || saving)
    .alert("入力を破棄して戻りますか？", isPresented: $confirmBack) {
      Button("破棄して戻る", role: .destructive) { dismiss() }
      Button("続ける", role: .cancel) {}
    } message: { Text("まだ登録されていません。変更したプリセット名・量・カテゴリーが消えます。") }
    .onChange(of: presetName) { _, _ in confirmed = false }
    .onChange(of: quantity) { _, _ in confirmed = false }
    .onChange(of: categoryID) { _, _ in confirmed = false }
  }

  private func register() {
    guard !saving, confirmed else { return }
    saving = true
    do {
      guard let amount = try FoodLabelParser.inputNumber(quantity) else { throw FoodFailure.invalidValue }
      let registration = try food.registration(
        confirmed: confirmed, presetName: presetName, defaultQuantity: amount, categoryID: categoryID)
      try model.save(registration.adding(to: model.state.catalog))
      didSave()
    } catch { saving = false; self.error = error.localizedDescription }
  }

  private func nutrientName(_ nutrient: FoodNutrient) -> String {
    switch nutrient {
    case .kcal: "エネルギー"
    case .protein: "たんぱく質（P）"
    case .fat: "脂質（F）"
    case .carbohydrate: "炭水化物（C）"
    }
  }
}
