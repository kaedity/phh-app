import PHHHubCore
import PhotosUI
import SwiftUI

struct FoodAnalysisPage: View {
  let date: String, slot: String, analyze: ((Data?, String) async throws -> FoodDraft)?,
    save: (FoodDraft) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var note = ""
  @State private var image: Data?
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var draft: FoodDraft?
  @State private var busy = false
  @State private var saving = false
  @State private var error = ""
  @State private var editing: FoodItemSnapshot?
  @State private var camera = false
  @State private var plate = false
  let plateAnalyze: SharedPlateAnalyzer?
  let platePreview: Bool
  let plateSave: ((FoodDraft, String, String, String) throws -> Void)?
  @State private var task: Task<Void, Never>?
  @State private var photoTask: Task<Void, Never>?
  init(
    date: String, slot: String, analyze: ((Data?, String) async throws -> FoodDraft)?,
    initialNote: String = "", plateAnalyze: SharedPlateAnalyzer? = nil, platePreview: Bool = false, plateSave: ((FoodDraft, String, String, String) throws -> Void)? = nil, save: @escaping (FoodDraft) throws -> Void
  ) {
    self.date = date
    self.slot = slot
    self.analyze = analyze
    self.save = save
    self.plateAnalyze = plateAnalyze; self.platePreview = platePreview; self.plateSave = plateSave
    _note = State(initialValue: initialNote)
  }
  var body: some View {
    Form {
      Section("\(date) · \(slot)") {
        TextField("食事の内容・量・商品の補足", text: $note, axis: .vertical).lineLimit(3...7)
          .accessibilityIdentifier("food-analysis-note")
        if let image, let ui = UIImage(data: image) {
          Image(uiImage: ui).resizable().scaledToFit().frame(maxHeight: 180)
          Button("写真を外す", role: .destructive) {
            releasePhoto()
          }
        }
        HStack {
          if UIImagePickerController.isSourceTypeAvailable(.camera) {
            Button("撮影", systemImage: "camera") { camera = true }
          }
          PhotosPicker(selection: $selectedPhoto, matching: .images) {
            Label("写真を選ぶ", systemImage: "photo")
          }
        }.buttonStyle(.borderless).disabled(busy)
        Button {
          runAnalysis()
        } label: {
          HStack {
            Label(draft == nil ? "解析する" : "補足を加えて再解析", systemImage: "sparkles")
            if busy {
              Spacer()
              MotionDots()
            }
          }
        }.disabled(
          busy || analyze == nil
            || (image == nil && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
      }
      Section {
        Button("食べる前と後の2枚で記録") { plate = true }
          .disabled(busy).accessibilityIdentifier("shared-plate-entry")
      }
      if let draft {
        Section("確認前の推定 · 合計には未反映") {
          if draft.items.isEmpty {
            Text("食品を確認できませんでした。文章を補足して再解析してください。").foregroundStyle(.secondary)
          }
          ForEach(draft.items) { i in
            Button {
              editing = i
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(i.name).font(.headline)
                  Spacer()
                  Image(systemName: "pencil")
                }
                Text("\(foodNumber(i.quantity))\(i.unit) · \(foodNumber(i.nutrients.kcal)) kcal")
                Text("\(i.source) · 信頼度\(i.confidence ?? "未設定")").font(.caption).foregroundStyle(
                  .secondary)
              }
            }
          .swipeActions { Button("食品を除く", role: .destructive) { self.draft?.items.removeAll { $0.id == i.id } } }
          }
          FoodTotalsView(total: .init(items: draft.items))
        }
        if !draft.uncertainty.isEmpty {
          Section("不確かな点") { ForEach(draft.uncertainty, id: \.self) { Text($0) } }
        }
        if !draft.questions.isEmpty {
          Section("確認が必要なこと") {
            ForEach(draft.questions, id: \.self) { q in
              VStack(alignment: .leading) {
                Text(q).font(.subheadline)
                TextField(
                  "回答・実際の量など",
                  text: Binding(
                    get: { self.draft?.answers[q] ?? "" }, set: { self.draft?.answers[q] = $0 })
                ).accessibilityLabel(q)
              }
            }
            Text("回答に合わせて食品・量を編集してください。追加の解析が必要なら、上の文章へ補足して再解析できます。").font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Section {
          Button {
            guard !saving else { return }; saving=true
            do {
              try save(draft)
              releasePhoto()
              dismiss()
            } catch { saving=false; self.error = error.localizedDescription }
          } label: { MotionSaveLabel(title: "確認して記録", busy: saving) }.disabled(busy || saving || draft.items.isEmpty).accessibilityLabel("確認して記録").accessibilityIdentifier("food-analysis-confirm")
        }
      }
      if !error.isEmpty { Section { Text(error).foregroundStyle(.red) } }
    }.navigationTitle("食事を確認").navigationBarTitleDisplayMode(.inline).toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("閉じる") {
          task?.cancel()
          releasePhoto()
          dismiss()
        }
      }
    }.onChange(of: selectedPhoto) { _, photo in
      guard let photo else { return }
      photoTask?.cancel()
      photoTask = Task {
        do {
          guard let data = try await photo.loadTransferable(type: Data.self),
            let ui = UIImage(data: data), let jpeg = ui.jpegData(compressionQuality: 0.7),
            jpeg.count <= 10_000_000
          else { throw FoodFailure.invalidValue }
          try Task.checkCancellation()
          image = jpeg
          error = ""
        } catch is CancellationError {} catch { self.error = "写真を読み込めませんでした。" }
        selectedPhoto = nil
      }
    }.sheet(isPresented: $plate) {
      NavigationStack {
        SharedPlatePage(date: date, slot: slot, analyze: plateAnalyze, preview: platePreview) { next, day, mealSlot, identity in
          if let plateSave { try plateSave(next, day, mealSlot, identity) } else { try save(next) }
          releasePhoto(); dismiss()
        }
      }
    }.sheet(item: $editing) { i in
      NavigationStack {
        FoodDraftItemEditor(item: i) { next in
          if let index = draft?.items.firstIndex(where: { $0.id == i.id }) {
            draft?.items[index] = next
          }
        }
      }
    }.sheet(isPresented: $camera) {
      FoodCamera { data in
        if (data?.count ?? 0) <= 10_000_000 { image = data } else { error = "写真の容量を小さくしてください。" }
        camera = false
      }
    }.onDisappear {
      task?.cancel()
      photoTask?.cancel()
      releasePhoto()
    }
  }
  private func releasePhoto() {
    photoTask?.cancel()
    photoTask = nil
    image = nil
    selectedPhoto = nil
  }
  private func runAnalysis() {
    guard let analyze else { return }
    busy = true
    error = ""
    let jpeg = image
    let text = note
    task = Task {
      do {
        guard text.count <= 8000 else { throw FoodFailure.invalidValue }
        let next = try await analyze(jpeg, text)
        try Task.checkCancellation()
        draft = next
        releasePhoto()
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
      busy = false
    }
  }
}
struct FoodCamera: UIViewControllerRepresentable {
  var result: (Data?) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(result) }
  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }
  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate
  {
    let result: (Data?) -> Void
    init(_ result: @escaping (Data?) -> Void) { self.result = result }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { result(nil) }
    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) { result((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.7)) }
  }
}
struct FoodDraftItemEditor: View {
  let item: FoodItemSnapshot, save: (FoodItemSnapshot) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var quantity: String
  @State private var unit: String
  @State private var kcal: String
  @State private var protein: String
  @State private var fat: String
  @State private var carbs: String
  @State private var error = ""
  init(item: FoodItemSnapshot, save: @escaping (FoodItemSnapshot) -> Void) {
    self.item = item
    self.save = save
    _name = State(initialValue: item.name)
    _quantity = State(initialValue: String(item.quantity))
    _unit = State(initialValue: item.unit)
    _kcal = State(initialValue: item.nutrients.kcal.map(String.init(describing:)) ?? "")
    _protein = State(initialValue: item.nutrients.protein.map(String.init(describing:)) ?? "")
    _fat = State(initialValue: item.nutrients.fat.map(String.init(describing:)) ?? "")
    _carbs = State(initialValue: item.nutrients.carbohydrate.map(String.init(describing:)) ?? "")
  }
  var body: some View {
    Form {
      Section("推定を修正") {
        LabeledContent("食品名") { TextField("食品名", text: $name) }
        LabeledContent("量") { TextField("量", text: $quantity).motionFieldError(error).keyboardType(.decimalPad) }
        LabeledContent("単位") { TextField("単位", text: $unit) }
        Button("量に合わせて栄養を計算") {
          do {
            guard let q = Double(quantity) else { throw FoodFailure.invalidValue }
            let scaled = try item.scaled(q / item.quantity)
            kcal = scaled.nutrients.kcal.map(String.init(describing:)) ?? ""
            protein = scaled.nutrients.protein.map(String.init(describing:)) ?? ""
            fat = scaled.nutrients.fat.map(String.init(describing:)) ?? ""
            carbs = scaled.nutrients.carbohydrate.map(String.init(describing:)) ?? ""
          } catch { self.error = error.localizedDescription }
        }
      }
      Section("表示量の栄養 · 空欄は未設定") {
        LabeledContent("kcal") { TextField("kcal", text: $kcal).keyboardType(.decimalPad) }
        LabeledContent("P（g）") { TextField("P（g）", text: $protein).keyboardType(.decimalPad) }
        LabeledContent("F（g）") { TextField("F（g）", text: $fat).keyboardType(.decimalPad) }
        LabeledContent("C（g）") { TextField("C（g）", text: $carbs).keyboardType(.decimalPad) }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.navigationTitle("食品を修正").navigationBarTitleDisplayMode(.inline).toolbar {
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
                id: item.id, name: name, quantity: q, unit: unit, preparation: item.preparation,
                source: "本人", versionID: item.versionID, confidence: item.confidence,
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
