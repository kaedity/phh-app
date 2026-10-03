import Foundation
import CryptoKit

public struct PlanningRecord: Equatable, Identifiable, Sendable {
  public let id: String, revision: Int, mutation: PlanningMutation
  public init(id: String, revision: Int, mutation: PlanningMutation) {
    self.id = id; self.revision = revision; self.mutation = mutation
  }
}
/// 仕様の列対応から型付き値を復元。JSON本文をセルへ保存しません。
public enum PlanningRows {
  struct Field: Decodable { let column: String, path: String, type: String, nullable: Bool }
  struct Child: Decodable { let table: String, path: String, model_id: Bool, fields: [Field] }
  struct Layout: Decodable { let key: String, model_id: Bool, fields: [Field], children: [Child] }
  static let layouts = try! JSONDecoder().decode([String: Layout].self, from:
    Data(contentsOf: Bundle.module.url(forResource: "planning-p5-layout", withExtension: "json")!))
  public static var tables: Set<String> {
    Set(layouts.keys).union(layouts.values.flatMap { $0.children.map(\.table) })
  }
  private static func value(_ field: Field, in object: [String: Any]) throws -> Cell {
    var v: Any = object
    for key in field.path.split(separator: ".").map(String.init) {
      v = (v as? [String: Any])?[key] ?? NSNull()
    }
    let cell = try JSONDecoder().decode(Cell.self, from: JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]))
    return cell
  }
  private static func assign(_ value: Any, path: [String], into object: inout [String: Any]) {
    guard let key = path.first else { return }
    if path.count == 1 { object[key] = value }
    else { var child = object[key] as? [String: Any] ?? [:]; assign(value, path: Array(path.dropFirst()), into: &child); object[key] = child }
  }
  private static func object(_ row: LocalRow, fields: [Field], modelID: Bool) throws -> [String: Any] {
    var object: [String: Any] = modelID ? ["id": row.entityID] : [:]
    for field in fields {
      guard let cell = row.values[field.column] else { throw HubError.invalidResponse }
      let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cell), options: [.fragmentsAllowed])
      assign(value, path: field.path.split(separator: ".").map(String.init), into: &object)
    }
    return object
  }
  public static func read(_ all: [LocalRow]) throws -> [PlanningRecord] {
    let relevant = tables, rows = all.filter { relevant.contains($0.table) }
    for row in rows { try Schema.validate(row) }
    guard Set(rows.map(\.id)).count == rows.count else { throw HubError.invalidResponse }
    let childrenByTable = Dictionary(grouping: rows.filter { $0.values["parent_id"]?.text != nil }, by: \.table)
      .mapValues { Dictionary(grouping: $0, by: { $0.values["parent_id"]?.text ?? "" }) }
    var result: [PlanningRecord] = [], used: Set<String> = []
    for root in rows.filter({ layouts[$0.table] != nil }) {
      guard root.active else { throw HubError.invalidResponse }
      let spec = layouts[root.table]!; var object = try object(root, fields: spec.fields, modelID: spec.model_id)
      for child in spec.children {
        let all = childrenByTable[child.table]?[root.entityID] ?? []
        let retired = all.filter { !$0.active }
        guard retired.allSatisfy({ $0.values["number"]?.number == 0 && $0.revision <= root.revision }) else { throw HubError.invalidResponse }
        used.formUnion(retired.map(\.id))
        let parts = all.filter { $0.active }
          .sorted { ($0.values["number"]?.number ?? 0) < ($1.values["number"]?.number ?? 0) }
        guard parts.enumerated().allSatisfy({ i,r in r.values["number"]?.number == Double(i+1) && r.revision == root.revision })
        else { throw HubError.invalidResponse }
        object[child.path] = try parts.map { try self.object($0, fields: child.fields, modelID: child.model_id) }
        used.formUnion(parts.map(\.id))
      }
      let mutation = try JSONDecoder().decode(PlanningMutation.self, from:
        JSONSerialization.data(withJSONObject: [spec.key: object], options: [.sortedKeys]))
      do {
        // 不変の版の論理版と、行自体の版は独立しています。
        try mutation.validate(entityID: root.entityID, expectedRevision: root.revision - 1)
      } catch { throw HubError.invalidResponse }
      result.append(.init(id: root.entityID, revision: root.revision, mutation: mutation)); used.insert(root.id)
    }
    guard used.count == rows.count else { throw HubError.invalidResponse }
    let goals = result.compactMap { $0.mutation.dailyGoal }, days = result.compactMap { $0.mutation.foodDay }
    guard Set(goals.map(\.date)).count == goals.count, Set(days.map(\.date)).count == days.count
    else { throw HubError.invalidResponse }
    let rules=result.compactMap { $0.mutation.goalRule }
    guard Set(rules.map(\.effectiveFrom)).count==rules.count,
      goals.allSatisfy({goal in rules.contains {$0.id==goal.ruleID && $0.revision>=goal.ruleRevision}})
    else { throw HubError.invalidResponse }
    do {
      _ = try SupplementLedger(products: result.compactMap { $0.mutation.product },
        plans: result.compactMap { $0.mutation.plan }, days: result.compactMap { $0.mutation.day })
    } catch { throw HubError.invalidResponse }
    return result.sorted { $0.id < $1.id }
  }
  /// 合成試験/プレビュー用の保存行計画。実APIはGASの同じ列契約で作ります。
  public static func rows(_ op: HubOperation, timestamp: String) throws -> [LocalRow] {
    try op.validate(); guard let mutation = op.planning,
      let pair = layouts.first(where: { "save_" + snake($0.value.key) == op.action })
    else { throw HubError.invalidOperation }
    let dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation)) as! [String: Any]
    guard let object = dict[pair.value.key] as? [String: Any] else { throw HubError.invalidOperation }
    func row(_ table: String, id: String, fields: [Field], object: [String: Any], extra: [String: Cell] = [:]) throws -> LocalRow {
      var values: [String: Cell] = ["id": .string(id), "revision": .number(Double(op.expected_revision+1)),
        "status": .string("active"), "created_at": .string(timestamp), "updated_at": .string(timestamp),
        "source_kind": .string("app"), "last_operation_id": .string(op.id)]
      for field in fields { values[field.column] = try value(field, in: object) }
      values.merge(extra) { _,new in new }
      let row = LocalRow(table: table, values: values); try Schema.validate(row); return row
    }
    var rows = [try row(pair.key, id: op.entity_id, fields: pair.value.fields, object: object)]
    for child in pair.value.children {
      guard let parts = object[child.path] as? [[String: Any]] else { throw HubError.invalidOperation }
      for (i,part) in parts.enumerated() {
        let hash = SHA256.hash(data: Data("\(op.entity_id)|\(child.table)|\(part["nutrientID"] ?? i)".utf8))
          .prefix(16).map { String(format: "%02x", $0) }.joined()
        let generated = "\(hash.prefix(8))-\(hash.dropFirst(8).prefix(4))-\("5"+hash.dropFirst(13).prefix(3))-\("a"+hash.dropFirst(17).prefix(3))-\(hash.suffix(12))"
        rows.append(try row(child.table, id: child.model_id ? part["id"] as! String : generated,
          fields: child.fields, object: part, extra: ["parent_id": .string(op.entity_id), "number": .number(Double(i+1))]))
      }
    }
    return rows
  }
  private static func snake(_ value: String) -> String {
    switch value { case "goalRule": "goal_rule"; case "dailyGoal": "daily_goal"; case "foodDay": "food_day"
    case "product": "supplement_product"; case "plan": "supplement_plan"; default: "supplement_day" }
  }
}
