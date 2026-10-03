import Foundation
import CryptoKit
import Testing
@testable import PHHHubCore

/// 長期の合成日別記録で、索引化前後の内容と読取時間を照合します。
@Suite(.serialized) struct PlanningRowsIndexTests {
  private struct Fixture: Decodable { let page: Delta }
  private struct FixtureRow: Codable {
    var table: String, record: [String: Cell]
    var local: LocalRow { .init(table: table, values: record) }
  }
  private struct RecordSnapshot: Codable {
    let id: String, revision: Int, mutation: PlanningMutation
    init(_ record: PlanningRecord) { id = record.id; revision = record.revision; mutation = record.mutation }
  }
  private struct Measurement: Codable {
    var years: Int, days: Int, records: Int, rows: Int, json_bytes: Int, snapshot_json_bytes: Int
    var rows_by_table: [String: Int]
    var fixture_sha256: String, snapshot_sha256: String
    var before_ms: [Double]?, after_ms: [Double]?
  }
  private struct Evidence: Codable {
    var synthetic = true
    var base_commit = "f392de8"
    var configuration = "release"
    var reader = "PlanningRows.read"
    var measurements: [Measurement]
  }
  private func uuid(_ value: Int) -> String {
    "00000000-0000-4000-a000-" + String(format: "%012d", value)
  }
  private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  private func encodedRecords(_ records: [PlanningRecord]) throws -> Data {
    try encoded(records.map(RecordSnapshot.init))
  }
  private func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  private func template() throws -> [FixtureRow] {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appending(path: "Server/planning-p5-fixture.json")))
    return fixture.page.changes.map { .init(table: $0.change.table_name, record: $0.record) }
  }
  private func fixture(days: Int) throws -> [FixtureRow] {
    let base = try template(), staticTables: Set<String> = ["GoalRules", "SupplementProducts", "SupplementProductNutrients", "SupplementPlans"]
    var result = base.filter { staticTables.contains($0.table) }
    for index in result.indices where ["GoalRules", "SupplementPlans"].contains(result[index].table) {
      result[index].record["effective_from"] = .string("2020-01-01")
    }
    let daily = base.filter { !staticTables.contains($0.table) }
    #expect(result.count == 8); #expect(daily.count == 9)
    let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
    let start = formatter.date(from: "2020-01-01")!
    for day in 0..<days {
      let roots = Dictionary(uniqueKeysWithValues: daily.filter { $0.record["parent_id"] == nil }.enumerated().map { ($0.element.local.entityID, uuid(400_001 + day * 100 + $0.offset)) })
      let date = formatter.string(from: start.addingTimeInterval(Double(day) * 86_400)), revision = Double(1 + day % 5), operationID = uuid(400_090 + day * 100)
      result += daily.enumerated().map { index, original in
        var row = original
        if let parent = original.record["parent_id"]?.text {
          row.record["id"] = .string(uuid(400_010 + day * 100 + index)); row.record["parent_id"] = .string(roots[parent]!)
        } else { row.record["id"] = .string(roots[original.local.entityID]!) }
        row.record["revision"] = .number(revision); row.record["last_operation_id"] = .string(operationID)
        if row.record["local_date"] != nil { row.record["local_date"] = .string(date) }
        if row.record["model_revision"] != nil { row.record["model_revision"] = .number(revision) }
        if row.table == "FoodDays" { row.record["completion_operation_id"] = .string(operationID) }
        return row
      }
    }
    return result
  }
  @Test func groupedReadKeepsRecordOrderOrdinalsRevisionsReferencesAndNulls() throws {
    let rows = try fixture(days: 7).map(\.local), expected = try PlanningRows.read(rows)
    #expect(try PlanningRows.read(Array(rows.reversed())) == expected)
    #expect(expected.map(\.id) == expected.map(\.id).sorted())
    for record in expected {
      let root = rows.first { PlanningRows.layouts[$0.table] != nil && $0.entityID == record.id }!
      #expect(record.revision == root.revision)
      if let goal = record.mutation.dailyGoal {
        let children = rows.filter { $0.table == "DailyGoalAdjustments" && $0.values["parent_id"]?.text == record.id }
        #expect(goal.manual.map(\.id) == children.map(\.entityID)); #expect(goal.total.kcal == 2100)
        #expect(goal.manual[0].delta.protein == 0); #expect(goal.ruleID == root.values["rule_id"]?.text)
      }
      if let day = record.mutation.day {
        #expect(day.nutrients.map(\.nutrientID) == ["kcal", "protein", "fat", "carbohydrate", "vitamin_b12"])
        #expect(day.nutrients[1].value == nil); #expect(day.nutrients[2].value == 0)
        #expect(day.revision == record.revision); #expect(day.planVersionID == root.values["plan_version_id"]?.text)
        #expect(day.productVersionID == root.values["product_version_id"]?.text)
      }
    }
    let unrelated = LocalRow(table: "HealthBatches", values: [:])
    #expect(try PlanningRows.read(rows + [unrelated]) == expected)
  }
  @Test func coincidentParentIDsRemainSeparatedByChildTable() throws {
    var rows = try fixture(days: 1).map(\.local)
    let goal = rows.firstIndex { $0.table == "DailyGoals" }!, adjustment = rows.firstIndex { $0.table == "DailyGoalAdjustments" }!
    let sharedID = rows.first { $0.table == "SupplementDays" }!.entityID
    rows[goal].values["id"] = .string(sharedID); rows[adjustment].values["parent_id"] = .string(sharedID)
    let records = try PlanningRows.read(rows)
    #expect(records.first { $0.mutation.dailyGoal != nil }?.mutation.dailyGoal?.manual.count == 1)
    #expect(records.first { $0.mutation.day != nil }?.mutation.day?.nutrients.count == 5)
  }
  @Test func groupedReadRejectsDuplicateOrphanMissingAndInvalidChildren() throws {
    let rows = try fixture(days: 2).map(\.local), nutrient = rows.firstIndex { $0.table == "SupplementDayNutrients" }!
    #expect(throws: HubError.invalidResponse) { try PlanningRows.read(rows + [rows[nutrient]]) }
    for (key, value) in [("parent_id", Cell.string(uuid(999))), ("number", .number(0)), ("number", .number(2)), ("revision", .number(2)), ("value", .string("invalid")), ("unit", .string("kg")), ("nutrient_id", .string("protein"))] {
      var bad = rows; bad[nutrient].values[key] = value
      #expect(throws: HubError.invalidResponse) { try PlanningRows.read(bad) }
    }
    var missing = rows; missing.remove(at: nutrient)
    #expect(throws: HubError.invalidResponse) { try PlanningRows.read(missing) }
    var missingReference = rows
    let day = missingReference.firstIndex { $0.table == "SupplementDays" }!
    missingReference[day].values["plan_version_id"] = .string(uuid(999))
    #expect(throws: HubError.invalidResponse) { try PlanningRows.read(missingReference) }
  }
  @Test func retiredChildrenStayIgnoredButStillRequireIdentityParentAndOldRevision() throws {
    let rows = try fixture(days: 2).map(\.local), expected = try PlanningRows.read(rows)
    for table in ["DailyGoalAdjustments", "SupplementDayNutrients"] {
      var retired = rows.first { $0.table == table }!
      retired.values["id"] = .string(uuid(999)); retired.values["status"] = .string("removed"); retired.values["number"] = .number(0)
      #expect(try PlanningRows.read(rows + [retired]) == expected)
      #expect(throws: HubError.invalidResponse) { try PlanningRows.read(rows + [retired, retired]) }
      for (key, value) in [("parent_id", Cell.string(uuid(998))), ("number", .number(1)), ("revision", .number(2))] {
        var bad = retired; bad.values[key] = value
        #expect(throws: HubError.invalidResponse) { try PlanningRows.read(rows + [bad]) }
      }
    }
  }
  /// PHH_PLANNING_READER_BENCHMARK_PHASE=before/after と OUTPUT=絶対JSONパスで実行します。
  @Test func longHistoryBenchmark() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let phase = environment["PHH_PLANNING_READER_BENCHMARK_PHASE"], let path = environment["PHH_PLANNING_READER_BENCHMARK_OUTPUT"] else { return }
    guard ["before", "after"].contains(phase), path.hasPrefix("/") else { throw HubError.configuration }
    let output = URL(fileURLWithPath: path)
    var measurements: [Measurement] = []
    for years in [1, 3, 5] {
      let fixtures = try fixture(days: 365 * years), rows = fixtures.map(\.local), bytes = try encoded(fixtures)
      var durations: [Double] = [], snapshot: Data?
      for _ in 0..<3 {
        let start = ContinuousClock.now, records = try PlanningRows.read(rows), duration = start.duration(to: .now)
        durations.append(Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
        let encoded = try encodedRecords(records)
        if let previous = snapshot { #expect(encoded == previous) }
        snapshot = encoded; #expect(records.count == 3 + 3 * 365 * years)
      }
      let measurement = Measurement(years: years, days: 365 * years, records: 3 + 3 * 365 * years, rows: rows.count, json_bytes: bytes.count, snapshot_json_bytes: snapshot!.count,
        rows_by_table: Dictionary(grouping: rows, by: \.table).mapValues(\.count), fixture_sha256: sha256(bytes), snapshot_sha256: sha256(snapshot!), before_ms: phase == "before" ? durations : nil, after_ms: phase == "after" ? durations : nil)
      print("planning_reader_phase=\(phase) years=\(years) days=\(measurement.days) records=\(measurement.records) rows=\(rows.count) json_bytes=\(bytes.count) median_ms=\(durations.sorted()[1]) fixture_sha256=\(measurement.fixture_sha256) snapshot_sha256=\(measurement.snapshot_sha256)")
      measurements.append(measurement)
    }
    var evidence = Evidence(measurements: measurements)
    if phase == "after" {
      evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: output))
      guard evidence.synthetic, evidence.base_commit == "f392de8", evidence.configuration == "release", evidence.measurements.count == measurements.count else { throw HubError.invalidResponse }
      for index in measurements.indices {
        let old = evidence.measurements[index], new = measurements[index]
        guard old.years == new.years, old.days == new.days, old.records == new.records, old.rows == new.rows, old.json_bytes == new.json_bytes, old.rows_by_table == new.rows_by_table,
          old.fixture_sha256 == new.fixture_sha256, old.snapshot_sha256 == new.snapshot_sha256, old.snapshot_json_bytes == new.snapshot_json_bytes, old.before_ms?.count == 3 else { throw HubError.invalidResponse }
        evidence.measurements[index].after_ms = new.after_ms
      }
    }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded(evidence).write(to: output, options: .atomic)
  }
}
