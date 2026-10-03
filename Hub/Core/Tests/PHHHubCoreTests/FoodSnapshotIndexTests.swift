import Foundation
import CryptoKit
import Testing
@testable import PHHHubCore

/// 合成fixtureを再利用し、索引化前後の値と規模別の読取時間を照合します。
@Suite(.serialized) struct FoodSnapshotIndexTests {
  private struct FixtureRow: Codable {
    var table: String
    var record: [String: Cell]
    var local: LocalRow { .init(table: table, values: record) }
  }
  private struct Measurement: Codable {
    var years: Int, meals: Int, rows: Int, json_bytes: Int, snapshot_json_bytes: Int
    var rows_by_table: [String: Int]
    var fixture_sha256: String, snapshot_sha256: String
    var before_ms: [Double]?, after_ms: [Double]?
  }
  private struct Evidence: Codable {
    var synthetic = true
    var base_commit = "a01d4e5"
    var configuration = "release"
    var reader = "FoodSnapshotReader.meals"
    var measurements: [Measurement]
  }
  private func uuid(_ value: Int) -> String {
    "00000000-0000-4000-a000-" + String(format: "%012d", value)
  }
  private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  private func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  private func template() throws -> [FixtureRow] {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    return try JSONDecoder().decode([FixtureRow].self, from: Data(contentsOf: root.appending(path: "Server/food-p4-rows-fixture.json")))
  }
  private func fixture(meals: Int) throws -> [FixtureRow] {
    let base = try template(), itemIDs = base.filter { $0.table == "MealItems" }.map { $0.local.entityID }
    #expect(base.count == 11); #expect(itemIDs.count == 2)
    let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
    let start = formatter.date(from: "2020-01-01")!
    return (0..<meals).flatMap { meal in
      let rootID = uuid(100_000 + meal * 100), childIDs = itemIDs.enumerated().map { uuid(100_001 + meal * 100 + $0.offset) }
      let date = formatter.string(from: start.addingTimeInterval(Double(meal) * 86_400))
      return base.enumerated().map { number, original in
        var row = original
        row.record["id"] = .string(row.table == "Meals" ? rootID : row.table == "MealItems" ? childIDs[itemIDs.firstIndex(of: original.local.entityID)!] : uuid(100_010 + meal * 100 + number))
        row.record["revision"] = .number(Double(1 + meal % 5))
        row.record["status"] = .string(meal % 17 == 0 ? "removed" : "active")
        row.record["last_operation_id"] = .string(uuid(100_090 + meal * 100))
        if row.table == "Meals" { row.record["local_date"] = .string(date) }
        if row.table == "MealItems" { row.record["meal_id"] = .string(rootID) }
        if row.table == "IntakeNutrients" { row.record["item_id"] = .string(childIDs[itemIDs.firstIndex(of: original.record["item_id"]!.text!)!]) }
        return row
      }
    }
  }
  @Test func groupedReadKeepsInputMealOrderOrdinalsRevisionsRemovedAndNullableValues() throws {
    let fixture = try fixture(meals: 23), rows = fixture.reversed().map(\.local)
    let result = try FoodSnapshotReader.meals(rows)
    #expect(result.map(\.id) == rows.filter { $0.table == "Meals" }.map(\.entityID))
    for meal in result {
      let root = rows.first { $0.table == "Meals" && $0.entityID == meal.id }!
      #expect(meal.revision == root.revision); #expect(meal.removed == !root.active)
      let children = rows.filter { $0.table == "MealItems" && $0.values["meal_id"]?.text == meal.id }.sorted { $0.values["number"]!.number! < $1.values["number"]!.number! }
      #expect(meal.items.map(\.id) == children.map(\.entityID))
      #expect(meal.items[0].nutrients.fat == 0); #expect(meal.items[1].nutrients.kcal == nil)
      #expect(meal.presetID == root.values["preset_id"]?.text); #expect(meal.presetRevision == 1)
      #expect(meal.items[0].versionID == children[0].values["reference_version"]?.text)
    }
  }
  @Test func groupedReadRejectsDuplicateOrphansMissingNutrientsAndInvalidMembership() throws {
    let original = try fixture(meals: 2).map(\.local)
    let child = original.firstIndex { $0.table == "MealItems" }!, nutrient = original.firstIndex { $0.table == "IntakeNutrients" }!
    var duplicate = original; duplicate.append(original[nutrient])
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(duplicate) }
    var orphan = original; orphan[child].values["meal_id"] = .string(uuid(999))
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(orphan) }
    orphan = original; orphan[nutrient].values["item_id"] = .string(uuid(999))
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(orphan) }
    var missing = original; missing.remove(at: nutrient)
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(missing) }
    for (key, value) in [("revision", Cell.number(2)), ("status", .string("active")), ("unit", .string("kg")), ("nutrient_id", .string("fat_g")), ("value_status", .string("unknown"))] {
      var bad = original; bad[nutrient].values[key] = value
      #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(bad) }
    }
    for (key, value) in [("number", Cell.number(2)), ("revision", .number(2)), ("status", .string("active"))] {
      var bad = original; bad[child].values[key] = value
      #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(bad) }
    }
  }
  @Test func retiredChildrenStillParticipateInDuplicateAndOrphanChecks() throws {
    var rows = try fixture(meals: 1).map(\.local)
    let child = rows.firstIndex { $0.table == "MealItems" && $0.values["number"]?.number == 2 }!, childID = rows[child].entityID
    rows[child].values["number"] = .null
    #expect(try FoodSnapshotReader.meals(rows)[0].items.count == 1)
    var duplicate = rows; duplicate.append(rows[child])
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(duplicate) }
    let nutrient = rows.firstIndex { $0.values["item_id"]?.text == childID }!
    var orphan = rows; orphan[nutrient].values["item_id"] = .string(uuid(999))
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(orphan) }
    var oldRetired = rows
    for index in oldRetired.indices where index != child { oldRetired[index].values["revision"] = .number(2) }
    oldRetired.removeAll { $0.table == "IntakeNutrients" && $0.values["item_id"]?.text == childID }
    #expect(try FoodSnapshotReader.meals(oldRetired)[0].items.count == 1)
    var newer = rows; newer[child].values["revision"] = .number(2)
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(newer) }
    rows[child].values["status"] = .string("active")
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(rows) }
  }
  @Test func groupedNutrientsPreserveDuplicateMacroAndUnknownValueChecks() throws {
    let original = try fixture(meals: 1).map(\.local)
    let kcal = original.firstIndex { $0.table == "IntakeNutrients" && $0.values["nutrient_id"]?.text == "kcal" && $0.values["value"] != .null }!
    var extra = original, duplicate = original[kcal]; duplicate.values["id"] = .string(uuid(999))
    extra.append(duplicate)
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(extra) }
    var missingMacro = original; missingMacro[kcal].values["nutrient_id"] = .string("protein_g"); missingMacro[kcal].values["unit"] = .string("g")
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(missingMacro) }
    let unknown = original.firstIndex { $0.table == "IntakeNutrients" && $0.values["value"] == .null }!
    var falselyKnown = original; falselyKnown[unknown].values["value_status"] = .string("label")
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(falselyKnown) }
    var falselyUnknown = original; falselyUnknown[kcal].values["value"] = .number(0); falselyUnknown[kcal].values["value_status"] = .string("unknown")
    #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(falselyUnknown) }
  }
  /// PHH_FOOD_READER_BENCHMARK_PHASE=before/after と OUTPUT=絶対JSONパスを指定して実行します。
  @Test func longHistoryBenchmark() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let phase = environment["PHH_FOOD_READER_BENCHMARK_PHASE"], let path = environment["PHH_FOOD_READER_BENCHMARK_OUTPUT"] else { return }
    guard ["before", "after"].contains(phase), path.hasPrefix("/") else { throw HubError.configuration }
    let output = URL(fileURLWithPath: path)
    var measurements: [Measurement] = []
    for years in [1, 3, 5] {
      let fixtures = try fixture(meals: 365 * years), rows = fixtures.map(\.local), bytes = try encoded(fixtures)
      var durations: [Double] = [], snapshot: Data?
      for _ in 0..<3 {
        let start = ContinuousClock.now, result = try FoodSnapshotReader.meals(rows), duration = start.duration(to: .now)
        durations.append(Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
        let encoded = try encoded(result)
        if let previous = snapshot { #expect(encoded == previous) }
        snapshot = encoded; #expect(result.count == 365 * years)
      }
      let measurement = Measurement(years: years, meals: 365 * years, rows: rows.count, json_bytes: bytes.count, snapshot_json_bytes: snapshot!.count,
        rows_by_table: Dictionary(grouping: rows, by: \.table).mapValues(\.count), fixture_sha256: sha256(bytes), snapshot_sha256: sha256(snapshot!), before_ms: phase == "before" ? durations : nil, after_ms: phase == "after" ? durations : nil)
      print("food_reader_phase=\(phase) years=\(years) meals=\(measurement.meals) rows=\(rows.count) json_bytes=\(bytes.count) median_ms=\(durations.sorted()[1]) fixture_sha256=\(measurement.fixture_sha256) snapshot_sha256=\(measurement.snapshot_sha256)")
      measurements.append(measurement)
    }
    var evidence = Evidence(measurements: measurements)
    if phase == "after" {
      evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: output))
      guard evidence.synthetic, evidence.base_commit == "a01d4e5", evidence.configuration == "release", evidence.measurements.count == measurements.count else { throw HubError.invalidResponse }
      for index in measurements.indices {
        let old = evidence.measurements[index], new = measurements[index]
        guard old.years == new.years, old.meals == new.meals, old.rows == new.rows, old.json_bytes == new.json_bytes, old.rows_by_table == new.rows_by_table,
          old.fixture_sha256 == new.fixture_sha256, old.snapshot_sha256 == new.snapshot_sha256, old.snapshot_json_bytes == new.snapshot_json_bytes, old.before_ms?.count == 3 else { throw HubError.invalidResponse }
        evidence.measurements[index].after_ms = new.after_ms
      }
    }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded(evidence).write(to: output, options: .atomic)
  }
}
