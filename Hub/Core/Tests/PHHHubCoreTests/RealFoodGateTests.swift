import Foundation
import Testing
@testable import PHHHubCore

/// 架空fixtureを使い、実データ指定の契約と端末内の再起動だけを確認します。
@Suite @MainActor struct RealFoodGateTests {
    private let owner = "synthetic@example.test"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    @Test func explicitFoodMarkerSurvivesWireAndHubRoundTripsForAllMealActions() throws {
        let before = try FoodHubTests().fixture().meal
        let meals = try [before, before.edited(factor: 2), before.edited(remove: true), before.edited(remove: true).edited(remove: false)]
        for meal in meals {
            let pending = try FoodPendingOperation(expectedRevision: meal.revision - 1, meal: meal)
            #expect(try FoodWireOperation(pending, environment: hubEnvironment).synthetic)
            let wire = try FoodWireOperation(pending, environment: hubEnvironment, synthetic: false)
            try wire.validate()
            let op = try wire.hubOperation()
            #expect(!op.synthetic); #expect(op.foodMeal == meal)
            let decoded = try JSONDecoder().decode(HubOperation.self, from: JSONEncoder().encode(op))
            try decoded.validate(); #expect(decoded == op)
            var draft = op; draft.approval_state = "draft"
            #expect(throws: HubError.invalidOperation) { try draft.validate() }
            var mismatched = op; mismatched.action = "confirm_meal"
            #expect(throws: HubError.invalidOperation) { try mismatched.validate() }
        }
    }
    @Test func legacyMealsAndPlanningStaySyntheticWhileApprovedTrainingKeepsExplicitMarker() throws {
        var legacy = HubOperation(action: "confirm_meal", meal: SyntheticMeal(date: "2026-10-03"))
        legacy.synthetic = false
        #expect(throws: HubError.invalidOperation) { try legacy.validate() }
        var planning = try PlanningStoreTests().ruleOperation()
        try planning.validate()
        planning.synthetic = false
        #expect(throws: HubError.invalidOperation) { try planning.validate() }
        var training = HubOperation(sessionID: UUID().uuidString, revision: 1, state: .completed)
        try training.validate()
        training.synthetic = false
        try training.validate()
        let decoded=try JSONDecoder().decode(HubOperation.self,from:JSONEncoder().encode(training))
        #expect(decoded.synthetic==false);try decoded.validate()
        training.approval_state="draft"
        #expect(throws:HubError.invalidOperation) {try training.validate()}
    }
    @Test func realCatalogAndAdditionPersistMarkersAcrossRestartWithoutChangingDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hub.sqlite")
        let fixture = try FoodHubTests().fixture(), canonical = try HubStore(owner: owner)
        try canonical.apply(fixture.page)
        let catalog = try FoodCatalogReader.catalog(canonical.rows())
        var hub: HubStore? = try HubStore(url: url, owner: owner)
        try FoodHubTests().ready(hub!)
        let store = FoodHubStore(hub: hub!, synthetic: false)
        try store.saveCatalog(catalog)
        let addition = try store.addPreset(catalog.presets[0].id, date: "2026-10-03", slot: "朝食")
        let queued = try hub!.pending()
        #expect(queued.map(\.operation.action) == ["save_food_version", "save_food_category", "save_food_preset", "confirm_food_meal"])
        #expect(queued.allSatisfy { !$0.operation.synthetic })
        for pending in queued { try pending.operation.validate() }
        hub = nil
        let reopened = try HubStore(url: url, owner: owner)
        #expect(try reopened.pending().allSatisfy { !$0.operation.synthetic })
        let screen = try FoodHubStore(hub: reopened).snapshot()
        #expect(screen.catalog == catalog); #expect(screen.pending.map(\.id) == [addition])
        let defaultStore = FoodHubStore(hub: reopened)
        let syntheticAddition = try defaultStore.addPreset(catalog.presets[0].id, date: "2026-10-03", slot: "夕食")
        #expect(try reopened.pending().first { $0.id == syntheticAddition }?.operation.synthetic == true)
    }
    @Test func realEditRemovalAndUnsentUndoKeepExplicitMarker() throws {
        let fixture = try FoodHubTests().fixture()
        for after in try [fixture.meal.edited(factor: 2), fixture.meal.edited(remove: true)] {
            let hub = try HubStore(owner: owner); try hub.apply(fixture.page)
            let store = FoodHubStore(hub: hub, synthetic: false)
            let id = try store.enqueue(after, operationID: UUID().uuidString)
            #expect(try hub.pending()[0].operation.synthetic == false)
            let change = try FoodUndoChange(operationID: id, before: fixture.meal, after: after, at: now)
            try store.undoChange(change, at: now)
            #expect(try hub.pending().isEmpty)
            #expect(try store.snapshot().confirmed == [fixture.meal])
        }
    }
    @Test func inflightRealAdditionUndoSurvivesRestartAndReceiptRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hub.sqlite")
        let meal = try FoodHubTests().fixture().meal
        let op = try FoodWireOperation(.init(expectedRevision: 0, meal: meal), environment: hubEnvironment, synthetic: false).hubOperation()
        var hub: HubStore? = try HubStore(url: url, owner: owner)
        try FoodHubTests().ready(hub!); try hub!.enqueue(op); try hub!.markAttempted(op.id)
        try FoodHubStore(hub: hub!).undoAddition(op.id)
        hub = nil
        let reopened = try HubStore(url: url, owner: owner)
        #expect(try reopened.pending()[0].operation.synthetic == false)
        #expect(try reopened.foodUndoRequested(op.id))
        let receipt = Receipt(environment: hubEnvironment, operation_id: op.id, status: "committed", entity_ids: [op.entity_id], revisions: [1], retryable: false)
        try reopened.finish(receipt, operation: op); try reopened.finish(receipt, operation: op)
        let cancellation = try #require(reopened.pending().first)
        #expect(try reopened.pending().count == 1)
        #expect(cancellation.operation.synthetic == false)
        #expect(cancellation.operation.action == "remove_food_meal")
        #expect(cancellation.operation.foodMeal?.items == meal.items)
    }
    @Test func inflightChangeUndoUsesOriginalMarkerEvenWhenFacadeUsesSyntheticDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hub.sqlite"), fixture = try FoodHubTests().fixture()
        let after = try fixture.meal.edited(remove: true)
        let op = try FoodWireOperation(.init(expectedRevision: 1, meal: after), environment: hubEnvironment, synthetic: false).hubOperation()
        let change = try FoodUndoChange(operationID: op.id, before: fixture.meal, after: after, at: now)
        var hub: HubStore? = try HubStore(url: url, owner: owner)
        try hub!.apply(fixture.page); try hub!.enqueue(op); try hub!.markAttempted(op.id)
        try FoodHubStore(hub: hub!).undoChange(change, at: now)
        hub = nil
        let reopened = try HubStore(url: url, owner: owner)
        #expect(try reopened.foodUndoRestoration(op.id)?.synthetic == false)
        let receipt = Receipt(environment: hubEnvironment, operation_id: op.id, status: "committed", entity_ids: [op.entity_id], revisions: [2], retryable: false)
        try reopened.finish(receipt, operation: op); try reopened.finish(receipt, operation: op)
        #expect(try reopened.pending().map(\.id) == [change.undoID])
        #expect(try reopened.pending()[0].operation.synthetic == false)
        #expect(try reopened.pending()[0].operation.foodMeal?.items == fixture.meal.items)
    }
    @Test func acknowledgedChangeRestartUndoUsesPersistedOriginalMarker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hub.sqlite"), fixture = try FoodHubTests().fixture()
        let after = try fixture.meal.edited(remove: true)
        var page = fixture.page
        for i in page.changes.indices where ["Meals", "MealItems", "IntakeNutrients"].contains(page.changes[i].change.table_name) {
            page.changes[i].record["revision"] = .number(2)
            page.changes[i].record["status"] = .string("removed")
            page.changes[i].change.revision = 2; page.changes[i].change.removed = true
        }
        let op = try FoodWireOperation(.init(expectedRevision: 1, meal: after), environment: hubEnvironment, synthetic: false).hubOperation()
        let change = try FoodUndoChange(operationID: op.id, before: fixture.meal, after: after, at: now)
        var hub: HubStore? = try HubStore(url: url, owner: owner)
        // 差分取得が受付番号の回復に先行した場合も、元Outboxの区分を保持します。
        try hub!.apply(page); try hub!.enqueue(op)
        let receipt = Receipt(environment: hubEnvironment, operation_id: op.id, status: "committed", entity_ids: [op.entity_id], revisions: [2], retryable: false)
        try hub!.finish(receipt, operation: op); hub = nil
        let reopened = try HubStore(url: url, owner: owner)
        try FoodHubStore(hub: reopened).undoChange(change, at: now)
        let restoration = try #require(reopened.pending().first)
        #expect(restoration.id == change.undoID)
        #expect(restoration.operation.synthetic == false)
        #expect(restoration.operation.foodMeal?.removed == false)
        #expect(restoration.operation.foodMeal?.items == fixture.meal.items)
    }
}
