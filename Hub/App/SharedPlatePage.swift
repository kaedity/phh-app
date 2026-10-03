import Observation
import PHHHubCore
import PhotosUI
import SwiftUI

typealias SharedPlateAnalyzer = (Data, Data?, String) async throws -> SharedPlateEstimate

@MainActor @Observable final class SharedPlateModel {
  static let live = SharedPlateModel(preview: false)
  #if DEBUG
  private static var clearedPreview = false
  #endif
  private let store: SharedPlatePhotoStore?
  var session: SharedPlateSession?
  var error = ""
  var reminder = false
  init(preview: Bool) {
    do {
      let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let openedStore = try SharedPlatePhotoStore(directory: root.appendingPathComponent(preview ? "SharedPlatePreview" : "Hub/SharedPlate"))
      #if DEBUG
      if preview && !Self.clearedPreview && !ProcessInfo.processInfo.arguments.contains("--plate-resume") { try openedStore.clear(); Self.clearedPreview = true }
      #endif
      store = openedStore
      checkDeadline(reload: true)
    } catch { store = nil; self.error = "一時保存を開けませんでした。" }
  }
  var hasStore: Bool { store != nil }
  @discardableResult func change(_ action: (inout SharedPlateSession) throws -> Void) -> Bool {
    do {
      guard var next = session, !next.expired(at: Date()) else { checkDeadline(); return false }
      try action(&next); try store?.save(next); session = next; error = ""
      return true
    } catch { self.error = error.localizedDescription; return false }
  }
  func capture(_ data: Data, after: Bool, date: String, slot: String) {
    do {
      guard let store else { throw FoodFailure.invalidValue }
      if after {
        change { $0.after = data; $0.estimate = nil; $0.draft = nil }
      } else {
        let next = try SharedPlateSession(before: data, date: date, slot: slot)
        guard session == nil else { throw FoodFailure.pendingEdit }
        try store.save(next); session = next; error = ""
      }
    } catch { self.error = error.localizedDescription }
  }
  func checkDeadline(reload: Bool = false) {
    do {
      let hadSession = session != nil
      if reload || session == nil { session = try store?.load() }
      else if session?.expired(at: Date()) == true { try clear() }
      if hadSession && session == nil { error = "12時間を過ぎたため、一時写真を消しました。"; reminder = false }
      if var next = session, next.takeReminder(at: Date()) {
        try store?.save(next); session = next; reminder = true
      }
    } catch { self.error = "一時写真を読み込めませんでした。" }
  }
  func clear() throws { try store?.clear(); session = nil; reminder = false }
}

struct SharedPlatePage: View {
  let date: String, slot: String, analyze: SharedPlateAnalyzer?, preview: Bool
  let save: (FoodDraft, String, String, String) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var model: SharedPlateModel
  @State private var selection: PhotosPickerItem?
  @State private var selectingAfter = false
  @State private var camera = false
  @State private var busy = false
  @State private var saved = false
  @State private var task: Task<Void, Never>?
  @State private var photoTask: Task<Void, Never>?
  private struct ItemEditing: Identifiable {
    let item: FoodItemSnapshot
    let isNew: Bool
    var id: String { item.id }
  }
  @State private var editing: ItemEditing?
  init(date: String, slot: String, analyze: SharedPlateAnalyzer?, preview: Bool,
       save: @escaping (FoodDraft, String, String, String) throws -> Void) {
    self.date = date; self.slot = slot; self.analyze = analyze; self.preview = preview; self.save = save
    _model = State(initialValue: preview ? SharedPlateModel(preview: true) : .live)
  }
  var body: some View {
    Form {
      Section {
        Text("皿全体が入るように、同じ角度で").font(.headline)
        Text("前後の差は大皿全体から減った量です。取り分けた場合は、最後に自分が食べた量へ直してください。")
        if !preview && analyze == nil { Text("写真はこの端末にだけ保存します。解析の実送信は利用開始の確認後に接続します。").font(.caption).foregroundStyle(.secondary) }
      }
      if let session = model.session {
        Section("食事中 · \(mockDay(session.date)) · \(session.slot)") {
          photo(session.before, title: "食べる前")
          TextField("料理・取り分けの補足", text: Binding(get: { model.session?.note ?? "" }, set: { text in model.change { $0.note = text } }), axis: .vertical)
          Picker("分けた人数（任意）", selection: Binding(get: { model.session?.people ?? 0 }, set: { people in model.change { $0.people = people == 0 ? nil : people } })) {
            Text("未指定").tag(0)
            ForEach(1...30, id: \.self) { Text("\($0)人").tag($0) }
          }
          Text("未確定 · 合計には未反映").accessibilityIdentifier("plate-unconfirmed")
        }.disabled(busy)
        if session.draft == nil {
          Section("食べた後") {
            if let after = session.after { photo(after, title: "残った量") }
            captureControls(after: true)
            Button(busy ? "解析しています…" : "前後2枚を解析する") { run(fraction: nil, manual: false) }
              .disabled(busy || session.after == nil || analyze == nil).accessibilityIdentifier("plate-analyze")
            if busy { MotionDots() }
          }
          Section("2枚目がないとき") {
            if model.reminder { Text("食事開始から3時間です。食べた量を選んでください。") }
            Button("全部食べた") { run(fraction: 1, manual: false) }.disabled(analyze == nil)
            Button("半分くらい") { run(fraction: 0.5, manual: false) }.disabled(analyze == nil)
            Button("自分で入力") { model.change { $0.beginManualEntry() } }
            Text("全部・半分は1枚目を解析します。「自分で入力」は写真を送らず、食品・量・栄養を入力します。")
          }.disabled(busy)
        }
        if let draft = session.draft {
          draftSection(draft)
          Section {
            Button("確認して記録") {
              guard !busy, !saved, let current = model.session, let draft = current.draft else { return }
              guard !current.expired(at: Date()) else { model.checkDeadline(); return }
              do {
                busy = true; defer { busy = false }
                try save(draft, current.date, current.slot, current.id)
                saved = true
                try model.clear(); Haptics.emit(.success); dismiss()
              } catch { model.error = error.localizedDescription }
            }.disabled(busy || saved || draft.items.isEmpty).accessibilityIdentifier("plate-confirm")
          }
        }
        Section {
          Button("一時写真を消して取消", role: .destructive) {
            do { task?.cancel(); photoTask?.cancel(); try model.clear(); dismiss() }
            catch { model.error = error.localizedDescription }
          }.disabled(busy)
        }
      } else {
        Section("1 · 食べる前を残す") {
          captureControls(after: false)
          Text("撮影後は食事中として残ります。閉じても続きから再開できます。写真は最大12時間で期限切れになります。")
        }.disabled(!model.hasStore)
      }
      if !model.error.isEmpty { Section { Text(model.error).foregroundStyle(.red).accessibilityIdentifier("plate-error") } }
    }.navigationTitle("大皿の前後写真").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
      .sheet(item: $editing) { selection in
        NavigationStack { FoodDraftItemEditor(item: selection.item, newItem: selection.isNew, close: { editing = nil }) { next in
          let accepted = model.change { current in
            if selection.isNew {
              guard let count = current.draft?.items.count, count < 50 else { throw FoodFailure.invalidValue }
              current.draft?.items.append(next)
            } else if let i = current.draft?.items.firstIndex(where: { $0.id == selection.item.id }) { current.draft?.items[i] = next }
          }
          guard accepted else { throw FoodFailure.invalidValue }
        } }
      }
      .sheet(isPresented: $camera) { FoodCamera { data in
        if let data { model.capture(data, after: selectingAfter, date: date, slot: slot) }
        camera = false
      } }
      .onChange(of: selection) { _, photo in
        guard let photo else { return }; photoTask?.cancel(); let isAfter = model.session != nil
        photoTask = Task {
          do {
            guard let data = try await photo.loadTransferable(type: Data.self), let image = UIImage(data: data),
                  let jpeg = image.jpegData(compressionQuality: 0.7), jpeg.count <= 10_000_000 else { throw FoodFailure.invalidValue }
            try Task.checkCancellation(); model.capture(jpeg, after: isAfter, date: date, slot: slot)
          } catch is CancellationError {} catch { model.error = "写真を読み込めませんでした。" }
          selection = nil
        }
      }
      .onChange(of: scenePhase) { _, phase in if phase == .active { model.checkDeadline(reload: true) } }
      .task {
        model.checkDeadline()
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(60)); model.checkDeadline() } catch { break }
        }
      }
      .onDisappear { task?.cancel(); photoTask?.cancel() }
  }
  @ViewBuilder private func captureControls(after: Bool) -> some View {
    HStack {
      if UIImagePickerController.isSourceTypeAvailable(.camera) {
        Button(after ? "後の写真を撮影" : "前の写真を撮影", systemImage: "camera") { selectingAfter = after; camera = true }
      }
      PhotosPicker(selection: $selection, matching: .images) { Label(after ? "後の写真を選ぶ" : "前の写真を選ぶ", systemImage: "photo") }
    }.buttonStyle(.borderless).disabled(busy)
    #if DEBUG
    if preview {
      Button(after ? "合成の後写真を用意" : "合成の前写真を用意") {
        let data = UIGraphicsImageRenderer(size: .init(width: 120, height: 80)).image { context in
          UIColor.systemGreen.setFill(); context.fill(.init(x: 0, y: 0, width: after ? 48 : 120, height: 80))
        }.jpegData(compressionQuality: 0.7)!
        model.capture(data, after: after, date: date, slot: slot)
      }
    }
    #endif
  }
  private func photo(_ data: Data, title: String) -> some View {
    VStack(alignment: .leading) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 130) }
    }
  }
  @ViewBuilder private func draftSection(_ draft: FoodDraft) -> some View {
    if let estimate = model.session?.estimate {
      Section("皿全体の比較 · 推定") {
        ForEach(Array(estimate.items.enumerated()), id: \.offset) { _, item in
          Text("\(item.name) · 前\(foodNumber(item.before_quantity))\(item.unit) / 残り\(foodNumber(item.remaining_quantity))\(item.unit) / 差\(foodNumber(item.consumed))\(item.unit) · \(item.confidence)")
        }
      }
    }
    Section("自分が食べた量 · 確認前") {
      if draft.items.isEmpty { Text("食品はまだありません。食べた食品と量を入力してください。栄養が不明なら空欄のまま保存できます。") }
      ForEach(draft.items) { item in
        Button { editing = ItemEditing(item: item, isNew: false) } label: {
          VStack(alignment: .leading) {
            Text(item.name).font(.headline)
            Text("\(foodNumber(item.quantity))\(item.unit) · \(foodNumber(item.nutrients.kcal)) kcal")
          }
        }.accessibilityIdentifier("plate-item")
      }
      Button("食品を手入力", systemImage: "plus") {
        do {
          let item = try FoodItemSnapshot(name: "未入力", quantity: 1, unit: "g", source: "本人", nutrients: .init(kcal: nil, protein: nil, fat: nil, carbohydrate: nil))
          editing = ItemEditing(item: item, isNew: true)
        } catch { model.error = error.localizedDescription }
      }.disabled(busy || draft.items.count >= 50)
      FoodTotalsView(total: .init(items: draft.items))
    }
    if !draft.uncertainty.isEmpty { Section("不確かな点") { ForEach(draft.uncertainty, id: \.self) { Text($0) } } }
    if !draft.questions.isEmpty {
      Section("確認が必要なこと") {
        ForEach(draft.questions, id: \.self) { question in
          Text(question)
          TextField("回答・量の編集を確認", text: Binding(get: { model.session?.draft?.answers[question] ?? "" }, set: { answer in model.change { $0.draft?.answers[question] = answer } }))
        }
      }
    }
  }
  private func run(fraction: Double?, manual: Bool) {
    guard !busy, let analyze, let current = model.session, !current.expired(at: Date()) else { model.checkDeadline(); return }
    busy = true; model.error = ""; Haptics.emit(.lightPress)
    task = Task {
      do {
        let estimate = try await analyze(current.before, fraction == nil ? current.after : nil, current.note)
        try Task.checkCancellation()
        guard model.session?.id == current.id, !current.expired(at: Date()) else { model.checkDeadline(); busy = false; return }
        let draft = try estimate.draft(fraction: fraction, people: current.people, manual: manual)
        model.change { $0.estimate = estimate; $0.draft = draft }
      } catch is CancellationError {} catch { model.error = error.localizedDescription }
      busy = false
    }
  }
}

/// 画面を閉じても、アプリ起動中/前面復帰時に期限切れを削除します。
struct SharedPlateLifetime: ViewModifier {
  @Environment(\.scenePhase) private var phase
  func body(content: Content) -> some View {
    content.task {
      SharedPlateModel.live.checkDeadline(reload: true)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(60)); SharedPlateModel.live.checkDeadline() }
        catch { break }
      }
    }.onChange(of: phase) { _, value in
      if value == .active { SharedPlateModel.live.checkDeadline(reload: true) }
    }
  }
}

#if DEBUG
@MainActor enum SharedPlatePreviewData {
  static func analyze(_ before: Data, _ after: Data?, _ note: String) async throws -> SharedPlateEstimate {
    try Task.checkCancellation()
    if ProcessInfo.processInfo.arguments.contains("--manual-no-analysis") { throw FoodFailure.invalidValue }
    return try SharedPlateEstimate.decode(JSONEncoder().encode(SharedPlateEstimate(items: [
      .init(name: "合成大皿", before: 100, remaining: after == nil ? 0 : 40, unit: "g",
            nutrients: .init(kcal: 200, protein: nil, fat: 0, carbohydrate: 40), confidence: "中")
    ])))
  }
}
#endif
