import ImageIO
import PHHHubCore
import PhotosUI
import SwiftUI
import UIKit
import Vision

/// 商品表示の画像は端末内のVisionだけへ渡します。登録時は確認済みの数値だけを保存します。
struct FoodLabelPage: View {
  @Bindable var model: FoodScreenModel
  let preview: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var imageData: Data?
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var labelReading: FoodLabelReading?
  @State private var entry: FoodLabelEntry
  @State private var categoryID: String?
  @State private var confirmed = false
  @State private var loading = false
  @State private var recognizing = false
  @State private var saving = false
  @State private var camera = false
  @State private var error = ""
  @State private var photoTask: Task<Void, Never>?
  @State private var recognitionTask: Task<Void, Never>?
  @State private var captureID = UUID()
  #if DEBUG
    @State private var previewText: String
  #endif

  init(model: FoodScreenModel, preview: Bool = false, initialOCRText: String = "") {
    self.model = model
    self.preview = preview
    #if DEBUG
      _previewText = State(initialValue: initialOCRText)
      let reading = initialOCRText.isEmpty ? nil : FoodLabelParser.read(initialOCRText)
    #else
      let reading: FoodLabelReading? = nil
    #endif
    _labelReading = State(initialValue: reading)
    _entry = State(initialValue: FoodLabelEntry(reading: reading ?? FoodLabelParser.read("")))
  }

  private var busy: Bool { loading || recognizing || saving }

  var body: some View {
    Form {
      captureSection
      #if DEBUG
        if preview { previewSection }
      #endif
      basisSection
      nutrientsSection
      if let reading = labelReading, !reading.warnings.isEmpty {
        Section("読み取りの確認事項") {
          ForEach(reading.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.circle").font(.subheadline)
          }
        }.accessibilityIdentifier("food-label-warnings")
      }
      if let reading = labelReading {
        Section {
          DisclosureGroup("読み取った文字を確認") {
            Text(reading.text).font(.caption).textSelection(.enabled)
              .accessibilityIdentifier("food-label-recognized-text")
          }
        }
      }
      confirmationSection
      if !error.isEmpty {
        Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("food-label-error") }
      }
    }
    .navigationTitle("成分表示から登録")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("閉じる") { releaseImage(); dismiss() }
          .accessibilityIdentifier("food-label-close")
      }
    }
    .onChange(of: selectedPhoto) { _, photo in
      guard let photo else { return }
      loadPhoto(photo)
    }
    .onChange(of: entry) { _, _ in confirmed = false }
    .onChange(of: categoryID) { _, _ in confirmed = false }
    .sheet(isPresented: $camera) {
      FoodCamera { data in
        camera = false
        guard let data else { return }
        acceptImage(data)
      }
    }
    .onDisappear { releaseImage() }
  }

  private var captureSection: some View {
    Section("成分表示を読み取る") {
      Text("成分表示が大きく写る写真を選んでください。画像の文字は端末内で読み取ります。")
        .font(.subheadline).foregroundStyle(.secondary)
      if let data = imageData, let ui = UIImage(data: data) {
        Image(uiImage: ui).resizable().scaledToFit().frame(maxHeight: 200)
          .accessibilityLabel("読み取る成分表示の写真")
          .accessibilityIdentifier("food-label-image")
        Button("写真を外す", role: .destructive) { releaseImage() }.disabled(busy)
          .accessibilityIdentifier("food-label-remove-photo")
      }
      HStack {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button("撮影", systemImage: "camera") { camera = true }
            .accessibilityIdentifier("food-label-camera")
        }
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
          Label("写真を選ぶ", systemImage: "photo")
        }.accessibilityIdentifier("food-label-select-photo")
      }.buttonStyle(.borderless).disabled(busy)
      Button(action: recognize) {
        HStack {
          Label("文字を読み取る", systemImage: "text.viewfinder")
          if recognizing || loading { Spacer(); ProgressView().accessibilityLabel("読み取り中") }
        }
      }.disabled(imageData == nil || busy).accessibilityIdentifier("food-label-recognize")
    }
  }

  private var basisSection: some View {
    Section("食品名と表示基準量") {
      LabeledContent("食品名") {
        TextField("食品名（プリセット名）", text: $entry.name)
          .accessibilityIdentifier("food-label-name")
      }
      if let basis = labelReading?.basis {
        Text("読み取った表示：\(basis.displayText)").font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("food-label-basis-evidence")
      }
      LabeledContent("基準量") {
        TextField("表示基準量", text: $entry.quantity).keyboardType(.decimalPad)
          .accessibilityIdentifier("food-label-quantity")
      }
      LabeledContent("単位") {
        TextField("g・食・袋など", text: $entry.unit)
          .accessibilityIdentifier("food-label-unit")
      }
      Text("下の栄養値は、この基準量に対応します。100g当たり・1食当たりなど、表示と同じ量を確認してください。")
        .font(.caption).foregroundStyle(.secondary)
      Picker("カテゴリー", selection: $categoryID) {
        Text("指定なし").tag(nil as String?)
        ForEach(model.state.catalog.categories.filter { !$0.archived }) { category in
          Text(category.name).tag(category.id as String?)
        }
      }.accessibilityIdentifier("food-label-category")
    }.disabled(busy)
  }

  private var nutrientsSection: some View {
    Section("基準量の栄養値") {
      nutrientField("kcal", value: $entry.kcal, id: "food-label-kcal")
      nutrientField("P（g）", value: $entry.protein, id: "food-label-protein")
      nutrientField("F（g）", value: $entry.fat, id: "food-label-fat")
      nutrientField("C（g）", value: $entry.carbohydrate, id: "food-label-carbohydrate")
      Text("不明な値は空欄にしてください。0は表示で確認できた値として保存します。")
        .font(.caption).foregroundStyle(.secondary)
    }.disabled(busy)
  }

  private func nutrientField(_ title: String, value: Binding<String>, id: String) -> some View {
    LabeledContent(title) {
      TextField("不明", text: value).keyboardType(.decimalPad).accessibilityIdentifier(id)
    }
  }

  private var confirmationSection: some View {
    Section("確認して登録") {
      Toggle("表示基準量と栄養値を確認しました", isOn: $confirmed)
        .disabled(busy).accessibilityIdentifier("food-label-reviewed")
      Text("登録後は食事画面のプリセットから使えます。写真と読み取った文字は保存しません。")
        .font(.caption).foregroundStyle(.secondary)
      Button(action: register) {
        MotionSaveLabel(title: "確認してプリセット登録", busy: saving)
      }.disabled(busy || !confirmed).accessibilityIdentifier("food-label-save")
    }
  }

  #if DEBUG
    private var previewSection: some View {
      Section("架空の成分表示 · 開発用") {
        TextEditor(text: $previewText).frame(minHeight: 100)
          .accessibilityIdentifier("food-label-preview-text")
        Button("架空の成分表示を入力") {
          previewText = """
            架空バー
            栄養成分表示 1食(35g)当たり
            エネルギー 150kcal
            たんぱく質 10.5g
            脂質 0g
            炭水化物 25g
            食塩相当量 0.3g
            """
          applyReading(previewText)
        }.accessibilityIdentifier("food-label-preview-sample")
        Button("文字から候補を読み取る") { applyReading(previewText) }
          .disabled(previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("food-label-preview-recognize")
      }.disabled(busy)
    }
  #endif

  private func loadPhoto(_ photo: PhotosPickerItem) {
    releaseImage()
    let identity = captureID
    loading = true
    photoTask = Task {
      do {
        guard let data = try await photo.loadTransferable(type: Data.self) else {
          throw FoodLabelImageFailure.unreadable
        }
        try Task.checkCancellation()
        guard captureID == identity else { return }
        acceptImage(data)
      } catch is CancellationError {
      } catch {
        guard captureID == identity else { return }
        self.error = error.localizedDescription
        loading = false
      }
      if captureID == identity { selectedPhoto = nil; photoTask = nil }
    }
  }

  private func acceptImage(_ data: Data) {
    loading = false
    guard data.count <= 20_000_000, UIImage(data: data) != nil else {
      error = FoodLabelImageFailure.unreadable.localizedDescription
      return
    }
    imageData = data
    labelReading = nil
    entry = FoodLabelEntry(reading: FoodLabelParser.read(""))
    confirmed = false
    error = ""
  }

  private func recognize() {
    guard let data = imageData, !busy else { return }
    recognitionTask?.cancel()
    let identity = captureID
    recognizing = true
    confirmed = false
    error = ""
    recognitionTask = Task {
      do {
        let text = try await FoodLabelTextRecognition.recognize(data)
        try Task.checkCancellation()
        guard captureID == identity else { return }
        applyReading(text)
      } catch is CancellationError {
      } catch {
        guard captureID == identity else { return }
        self.error = error.localizedDescription
      }
      if captureID == identity { recognizing = false; recognitionTask = nil }
    }
  }

  private func applyReading(_ text: String) {
    let next = FoodLabelParser.read(text)
    labelReading = next
    entry = FoodLabelEntry(reading: next)
    confirmed = false
    error = ""
  }

  private func register() {
    guard !busy, confirmed else { return }
    saving = true
    do {
      let registration = try entry.registration(confirmed: confirmed, categoryID: categoryID)
      try model.save(registration.adding(to: model.state.catalog))
      releaseImage()
      dismiss()
    } catch {
      saving = false
      self.error = error.localizedDescription
    }
  }

  private func releaseImage() {
    captureID = UUID()
    photoTask?.cancel()
    recognitionTask?.cancel()
    photoTask = nil
    recognitionTask = nil
    imageData = nil
    selectedPhoto = nil
    loading = false
    recognizing = false
  }
}

private enum FoodLabelImageFailure: Error, LocalizedError {
  case unreadable, noText
  var errorDescription: String? {
    switch self {
    case .unreadable: "写真を読み込めませんでした。20MB以内の写真を選んでください。"
    case .noText: "文字を読み取れませんでした。成分表示を明るく大きく写して撮り直すか、表示の値を入力してください。"
    }
  }
}

private enum FoodLabelTextRecognition {
  static func recognize(_ data: Data) async throws -> String {
    // Visionの同期処理を画面のMainActorから離します。画像を外部へ送る処理はありません。
    let worker = Task.detached(priority: .userInitiated) { () throws -> String in
      try Task.checkCancellation()
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["ja-JP", "en-US"]
      request.usesLanguageCorrection = false
      request.customWords = ["栄養成分表示", "エネルギー", "たんぱく質", "脂質", "炭水化物", "食塩相当量"]
      let source = CGImageSourceCreateWithData(data as CFData, nil)
      let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
      let orientationValue = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
      let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
      let handler = VNImageRequestHandler(data: data, orientation: orientation, options: [:])
      try handler.perform([request])
      try Task.checkCancellation()
      guard let observations = request.results, !observations.isEmpty else {
        throw FoodLabelImageFailure.noText
      }
      // 横並びのラベルと数字を1行へ戻し、別行の成分と結び付ける事故を減らします。
      let sorted = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
      var rows: [[VNRecognizedTextObservation]] = []
      for observation in sorted {
        if let previous = rows.last?.first,
          abs(previous.boundingBox.midY - observation.boundingBox.midY)
            <= min(previous.boundingBox.height, observation.boundingBox.height) * 0.55
        {
          rows[rows.count - 1].append(observation)
        } else { rows.append([observation]) }
      }
      let text = rows.map { row in
        row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
          .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
      }.joined(separator: "\n")
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw FoodLabelImageFailure.noText
      }
      return text
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}
