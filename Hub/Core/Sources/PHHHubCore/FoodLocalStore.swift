import Foundation

public enum FoodSendState: String, Codable, Sendable { case queued, sending, needsReview }
public struct FoodPendingOperation: Codable, Equatable, Identifiable, Sendable {
  public let id: String, expectedRevision: Int, meal: FoodMeal
  public var state: FoodSendState, attempted: Bool, undoRequested: Bool, error: String?
  public var undoReplacement: FoodMeal?
  public var undoOperationID: String?
  public init(id: String = UUID().uuidString, expectedRevision: Int, meal: FoodMeal) throws {
    self.id = id
    self.expectedRevision = expectedRevision
    self.meal = meal
    state = .queued
    attempted = false
    undoRequested = false
    error = nil
    undoReplacement = nil; undoOperationID = nil
    try validate()
  }
  public func validate() throws {
    try FoodRules.id(id)
    try meal.validate()
    guard expectedRevision >= 0, meal.revision == expectedRevision + 1,
      expectedRevision > 0 || !meal.removed
    else { throw FoodFailure.invalidValue }
    if let undoReplacement {
      try undoReplacement.validate()
      guard undoRequested, undoReplacement.id == meal.id, undoReplacement.revision == meal.revision+1,
        let undoOperationID, undoOperationID != id else { throw FoodFailure.invalidValue }
      try FoodRules.id(undoOperationID)
    }
  }
}
/// P4の端末保存・送信順の準備用。Google未配置の間に本番のOutboxと混ぜない別契約です。
public struct FoodLocalState: Codable, Equatable, Sendable {
  public let schemaVersion: Int, environment: String
  public var catalog: FoodCatalog, confirmed: [FoodMeal], pending: [FoodPendingOperation]
  public init(
    catalog: FoodCatalog, confirmed: [FoodMeal] = [], pending: [FoodPendingOperation] = []
  ) throws {
    schemaVersion = 1
    environment = "PHH_P4_LOCAL_SYNTHETIC"
    self.catalog = catalog
    self.confirmed = confirmed
    self.pending = pending
    try validate()
  }
  public func validate() throws {
    guard schemaVersion == 1, environment == "PHH_P4_LOCAL_SYNTHETIC" else {
      throw FoodFailure.invalidValue
    }
    try catalog.validate()
    for m in confirmed { try m.validate() }
    for op in pending { try op.validate() }
    guard Set(confirmed.map(\.id)).count == confirmed.count,
      Set(pending.map(\.id)).count == pending.count,
      Set(pending.map { $0.meal.id }).count == pending.count
    else { throw FoodFailure.duplicateID }
    for op in pending {
      let current = confirmed.first { $0.id == op.meal.id }
      guard (current?.revision ?? 0) == op.expectedRevision else {
        throw FoodFailure.revisionConflict
      }
    }
  }
}
@MainActor public final class FoodLocalStore {
  public private(set) var state: FoodLocalState
  private let url: URL?
  public init(url: URL? = nil, initial: FoodLocalState) throws {
    self.url = url
    if let url, FileManager.default.fileExists(atPath: url.path) {
      state = try JSONDecoder().decode(FoodLocalState.self, from: Data(contentsOf: url))
    } else {
      state = initial
    }
    try state.validate()
    // 応答前の終了は、同じIDを再送。未送信として取り消してはいけません。
    for i in state.pending.indices where state.pending[i].state == .sending {
      state.pending[i].state = .queued
    }
    try persist(state)
  }
  private func persist(_ value: FoodLocalState) throws {
    try value.validate()
    guard let url else { return }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
  }
  private func mutate(_ block: (inout FoodLocalState) throws -> Void) throws {
    var next = state
    try block(&next)
    try persist(next)
    state = next
  }
  public func saveCatalog(_ catalog: FoodCatalog) throws { try mutate { $0.catalog = catalog } }
  @discardableResult public func enqueue(_ meal: FoodMeal, operationID: String = UUID().uuidString)
    throws -> String
  {
    let expected = meal.revision - 1
    let op = try FoodPendingOperation(id: operationID, expectedRevision: expected, meal: meal)
    if let old = state.pending.first(where: { $0.id == operationID }) {
      guard old.meal == meal && old.expectedRevision == expected else {
        throw FoodFailure.duplicateID
      }
      return operationID
    }
    guard !state.pending.contains(where: { $0.meal.id == meal.id }) else {
      throw FoodFailure.pendingEdit
    }
    try mutate { $0.pending.append(op) }
    return op.id
  }
  @discardableResult public func addPreset(_ id: String, date: String, slot: String) throws
    -> String
  {
    guard let preset = state.catalog.presets.first(where: { $0.id == id }) else {
      throw FoodFailure.missingReference
    }
    let meal = try FoodMeal(
      date: date, slot: slot, items: state.catalog.snapshot(id), presetID: id,
      presetRevision: preset.revision)
    return try enqueue(meal)
  }
  public func edit(
    _ id: String, factor: Double = 1, date: String? = nil, slot: String? = nil, remove: Bool = false
  ) throws {
    guard let current = state.confirmed.first(where: { $0.id == id && !$0.removed }) else {
      throw FoodFailure.missingReference
    }
    try enqueue(current.edited(factor: factor, date: date, slot: slot, remove: remove))
  }
  public func beginSending(_ operationID: String) throws -> FoodPendingOperation {
    guard let i = state.pending.firstIndex(where: { $0.id == operationID }),
      state.pending[i].state != .needsReview
    else { throw FoodFailure.invalidValue }
    try mutate {
      $0.pending[i].state = .sending
      $0.pending[i].attempted = true
    }
    return state.pending[i]
  }
  public func acknowledge(_ operationID: String, confirmed: FoodMeal) throws {
    guard let i = state.pending.firstIndex(where: { $0.id == operationID }) else {
      // 応答処理の再実行は、すでに保存済みの同一確定値なら何もしません。
      guard state.confirmed.contains(confirmed) else { throw FoodFailure.invalidReceipt }
      return
    }
    guard state.pending[i].attempted, state.pending[i].meal == confirmed else { throw FoodFailure.invalidReceipt }
    try mutate { next in
      let op = next.pending.remove(at: i)
      next.confirmed.removeAll { $0.id == confirmed.id }
      next.confirmed.append(confirmed)
      if let restoration = op.undoReplacement, let undoID = op.undoOperationID {
        next.pending.append(try .init(id: undoID, expectedRevision: confirmed.revision, meal: restoration))
      } else if op.undoRequested && !confirmed.removed {
        next.pending.append(
          try .init(expectedRevision: confirmed.revision, meal: confirmed.edited(remove: true)))
      }
    }
  }
  public func retry(_ operationID: String) throws {
    guard let i = state.pending.firstIndex(where: { $0.id == operationID }),
      state.pending[i].state != .needsReview
    else { throw FoodFailure.invalidValue }
    try mutate { $0.pending[i].state = .queued }
  }
  public func reject(_ operationID: String, reason: String) throws {
    guard let i = state.pending.firstIndex(where: { $0.id == operationID }) else {
      throw FoodFailure.invalidValue
    }
    try mutate {
      $0.pending[i].state = .needsReview
      $0.pending[i].error = reason
    }
  }
  public func undoAddition(_ operationID: String) throws {
    guard let i = state.pending.firstIndex(where: { $0.id == operationID }) else {
      // 確定後は操作IDから対象を特定できないので、呼出側が対象食事IDを保持して取消操作を作ります。
      throw FoodFailure.invalidValue
    }
    guard state.pending[i].expectedRevision == 0 else { throw FoodFailure.invalidValue }
    try mutate { next in
      if !next.pending[i].attempted {
        next.pending.remove(at: i)
      } else {
        next.pending[i].undoRequested = true
      }
    }
  }
  public func undoChange(_ change: FoodUndoChange, at: Date = .now) throws {
    try change.validate(); guard change.available(at: at) else { throw FoodFailure.invalidValue }
    if state.pending.contains(where: { $0.id == change.undoID }) { return }
    if let index = state.pending.firstIndex(where: { $0.id == change.operationID }) {
      guard state.pending[index].meal == change.after, state.pending[index].state != .needsReview else { throw FoodFailure.pendingEdit }
      let restored = try change.restoration(current: state.pending[index].meal)
      try mutate { next in
        if !next.pending[index].attempted { next.pending.remove(at: index) }
        else { next.pending[index].undoRequested=true; next.pending[index].undoReplacement=restored; next.pending[index].undoOperationID=change.undoID }
      }
    } else {
      guard let current = state.confirmed.first(where: { $0.id == change.after.id }) else { throw FoodFailure.missingReference }
      try enqueue(change.restoration(current: current), operationID: change.undoID)
    }
  }
  public func discardRejected(_ id: String) throws {
    guard state.pending.contains(where: { $0.id == id && $0.state == .needsReview }) else {
      throw FoodFailure.invalidValue
    }
    try mutate { $0.pending.removeAll { $0.id == id } }
  }
}
