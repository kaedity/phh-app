import Foundation
import Testing
@testable import PHHHubCore

struct SharedPlateTests {
  @Test func manualEntryKeepsLocalPhotoAndStartsWithoutInventedFoods() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SharedPlatePhotoStore(directory: directory)
    var session = try SharedPlateSession(before: Data([1, 2, 3]), date: "2026-10-04", slot: "昼食")
    session.note = "自分の取り分を入力"; session.beginManualEntry()
    try store.save(session)
    let recovered = try #require(try store.load())
    #expect(recovered.before == Data([1, 2, 3])); #expect(recovered.estimate == nil)
    #expect(recovered.note == session.note); #expect(recovered.draft?.items.isEmpty == true)
    #expect(FoodTotal.day("2026-10-04", meals: []).known[.kcal] == 0)
    #expect(throws: FoodFailure.invalidValue) { try recovered.draft?.confirm(date: "2026-10-04", slot: "昼食") }
  }
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func estimate(left: Double = 40) throws -> SharedPlateEstimate {
    .init(items: [.init(name: "合成大皿", before: 100, remaining: left, unit: "g",
      nutrients: try .init(kcal: 200, protein: nil, fat: 0, carbohydrate: 40), confidence: "中")])
  }
  @Test func subtractionAndPersonalPortionAreUnconfirmedAndNeverDividedByPeople() throws {
    let response = try SharedPlateEstimate.decode(JSONEncoder().encode(estimate()))
    let draft = try response.draft(people: 3)
    #expect(draft.items[0].quantity == 60); #expect(draft.items[0].nutrients.kcal == 120)
    #expect(draft.items[0].nutrients.protein == nil); #expect(draft.items[0].nutrients.fat == 0)
    #expect(throws: FoodFailure.unresolvedQuestions) { try draft.confirm(date: "2026-10-03", slot: "夕食") }
    let untouched = FoodTotal.day("2026-10-03", meals: [])
    #expect(untouched.known[.kcal] == 0)
  }
  @Test func allHalfManualAndNothingConsumed() throws {
    let response = try estimate()
    #expect(try response.draft(fraction: 1).items[0].nutrients.kcal == 200)
    #expect(try response.draft(fraction: 0.5).items[0].quantity == 50)
    #expect(try response.draft(fraction: 1, manual: true).questions.count == 1)
    #expect(try estimate(left: 100).draft().items.isEmpty)
    for left in [-1.0, 101, Double.infinity] { #expect(throws: FoodFailure.invalidValue) { try estimate(left: left).draft() } }
  }
  @Test func localPhotosSurviveRestartAndReminderIsOnceThenExpireAtTwelveHours() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SharedPlatePhotoStore(directory: directory)
    var session = try SharedPlateSession(before: Data([1, 2, 3]), date: "2026-10-03", slot: "夕食", now: now)
    let earlyReminder = session.takeReminder(at: now.addingTimeInterval(3 * 3600 - 1)); #expect(!earlyReminder)
    try store.save(session, now: now)
    var recovered = try SharedPlatePhotoStore(directory: directory).load(now: now.addingTimeInterval(3 * 3600))!
    #expect(recovered.before == session.before); let firstReminder = recovered.takeReminder(at: now.addingTimeInterval(3 * 3600)); #expect(firstReminder)
    try store.save(recovered, now: now.addingTimeInterval(3 * 3600))
    recovered = try store.load(now: now.addingTimeInterval(4 * 3600))!
    let repeatedReminder = recovered.takeReminder(at: now.addingTimeInterval(4 * 3600)); #expect(!repeatedReminder)
    #expect(try store.load(now: now.addingTimeInterval(12 * 3600)) == nil)
    #expect(!FileManager.default.fileExists(atPath: store.file.path))
  }
  @Test func cancelAndConfirmClearOnlyTheTemporaryCopy() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SharedPlatePhotoStore(directory: directory)
    let source = directory.appendingPathComponent("original.jpg"); try Data([1]).write(to: source)
    var session = try SharedPlateSession(before: Data(contentsOf: source), date: "2026-10-03", slot: "夕食", now: now)
    session.after = Data([2]); session.draft = try estimate().draft()
    try store.save(session, now: now); _ = try session.draft!.confirm(date: session.date, slot: session.slot)
    try store.clear(); #expect(try store.load(now: now) == nil); #expect(FileManager.default.fileExists(atPath: source.path))
    try store.save(session, now: now); try store.clear(); #expect(try store.load(now: now) == nil)
  }
  @Test @MainActor func confirmationRetryUsesSameMealAndOperationAfterPhotoCleanupFailure() throws {
    let store = try FoodLocalStore(initial: .init(catalog: .init()))
    let identity = UUID().uuidString, draft = try estimate().draft()
    let first = try FoodCommit.confirm(draft, date: "2026-10-03", slot: "夕食", store: store, identity: identity)
    let retried = try FoodCommit.confirm(draft, date: "2026-10-03", slot: "夕食", store: store, identity: identity)
    #expect(first.mealID == retried.mealID); #expect(first.operationID == retried.operationID)
    #expect(store.state.pending.count == 1)
  }
  @Test func twoImagesOrderedAndFallbackUsesOneOnlyAfterExplicitSelection() throws {
    let body = try SharedPlateRequest.body(model: "synthetic", before: Data([1]), after: Data([2]), note: "3人")
    let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let input = json["input"] as! [[String: Any]], content = input[0]["content"] as! [[String: Any]]
    let images = content.filter { $0["type"] as? String == "input_image" }
    #expect(images.count == 2); #expect((images[0]["image_url"] as! String).hasSuffix("AQ==")); #expect((images[1]["image_url"] as! String).hasSuffix("Ag=="))
    #expect(json["store"] as? Bool == false); #expect(json["stream"] as? Bool == true)
    let single = try JSONSerialization.jsonObject(with: SharedPlateRequest.body(model: "synthetic", before: Data([1]), after: nil, note: "")) as! [String: Any]
    #expect(((single["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]).filter { $0["type"] as? String == "input_image" }.count == 1)
  }
}
