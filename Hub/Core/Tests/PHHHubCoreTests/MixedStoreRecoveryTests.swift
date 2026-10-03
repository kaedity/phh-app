import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct MixedStoreRecoveryTests {
    struct Queued: Equatable {
        let payload: Data, state: PendingState, message: String, retry: Date, attempts: Int, sequence: Int
    }
    struct Checkpoint: Equatable {
        let rows: [LocalRow], queue: [Queued], food: FoodScreenSnapshot
        let cursor: Int, generation: Int, foodContract: Int, planningContract: Int, healthContract: Int
        let scopes: [HealthImportProgress], samples: [HealthLocalRecord]
        let policy: HealthUploadPolicy, dirty: [HealthDirtyDay], statistic: HealthDailyStatistics?
        let undo: Bool
    }
    struct Setup {
        let food: HubOperation, goal: HubOperation, scope: HealthQueryScope, samples: [HealthSample]
    }
    let h = HealthTests(), day = "2026-10-03"

    func setup(_ store: HubStore) throws -> Setup {
        let fixture = try FoodHubTests().fixture(); try store.apply(fixture.page)
        let cursor = try store.cursor
        try store.apply(Delta(schema_version: 1, environment: hubEnvironment, generation: 1,
            health_contract: 1, planning_contract: 1, food_contract: 1,
            snapshot_revision: cursor, changes: [], next_cursor: cursor, has_more: false))
        let item = try FoodItemSnapshot(name: "架空の混在保存", quantity: 1, unit: "皿", source: "推定",
            confidence: "中", nutrients: .init(kcal: 120, protein: nil, fat: 0, carbohydrate: 15))
        let meal = try FoodMeal(date: day, slot: "昼食", items: [item])
        let food = try FoodWireOperation(.init(expectedRevision: 0, meal: meal), environment: hubEnvironment).hubOperation()
        let goal = try PlanningStoreTests().ruleOperation()
        try store.enqueue(food); try PlanningHubStore(hub: store).enqueue([goal])
        let scope = try h.scope(metric: .stepCount), a = try h.sample(500, metric: .stepCount), b = try h.sample(600, metric: .stepCount, at: h.time.addingTimeInterval(60))
        try store.registerHealthScope(scope)
        try store.ingestHealth(h.page(scope, added: [a]), synthetic: true)
        let dirty = try #require(store.healthDirtyDays(metric: .stepCount).first)
        try store.commitHealthStatistics(HealthDailyStatistics(metric: .stepCount, date: day, value: 700, measuredAt: h.time), dirty: dirty, synthetic: true)
        try store.ingestHealth(h.page(scope, anchor: Data([1]), next: 2, added: [b]), synthetic: true)
        try store.setHealthUploadPolicy(HealthUploadPolicy(allowedMetrics: [.stepCount], from: day, authorizedAt: h.time))
        try store.markAttempted(food.id); try store.undoFoodAddition(food)
        try store.deferOperation(goal.id, state: .authentication, message: "架空の再認証待ち", retryAt: h.time.addingTimeInterval(300))
        return Setup(food: food, goal: goal, scope: scope, samples: [a,b])
    }
    func checkpoint(_ store: HubStore, setup: Setup) throws -> Checkpoint {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let queue = try store.pending().map { Queued(payload: try encoder.encode($0.operation), state: $0.state,
            message: $0.message, retry: $0.retryAt, attempts: $0.attempts, sequence: $0.sequence) }
        return try Checkpoint(rows: store.rows(), queue: queue, food: FoodHubStore(hub: store).snapshot(),
            cursor: store.cursor, generation: store.generation, foodContract: store.foodContract,
            planningContract: store.planningContract, healthContract: store.healthContract,
            scopes: store.healthScopes(), samples: setup.samples.map { try #require(try store.healthRecord($0.id)) },
            policy: store.healthUploadPolicy(), dirty: store.healthDirtyDays(metric: .stepCount),
            statistic: store.healthStatistics(metric: .stepCount, date: day), undo: store.foodUndoRequested(setup.food.id))
    }
    @Test func mixedFoodPlanningHealthStateSurvivesSQLiteRestartAndAccountRejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hub.sqlite")
        var setup: Setup!, before: Checkpoint!
        do {
            let store = try HubStore(url: url, owner: "synthetic@example.test")
            setup = try self.setup(store); before = try checkpoint(store, setup: setup)
            #expect(before.queue.count == 5); #expect(before.undo)
            #expect(before.statistic?.value == 700); #expect(before.dirty.count == 1)
        }
        #expect(throws: HubError.accountChanged) { _ = try HubStore(url: url, owner: "different@example.test") }
        let reopened = try HubStore(url: url, owner: "synthetic@example.test")
        #expect(try checkpoint(reopened, setup: setup) == before)
        try reopened.resumeAuthentication()
        // deferOperation records an attempted request; reconnect must not make it cancellable as unsent.
        #expect(throws: FoodFailure.pendingEdit) { try PlanningHubStore(hub: reopened).cancelUnsent(setup.goal.id) }
        #expect(try reopened.pending().count == 5)
        let resumedGoal = try #require(try reopened.pending().first { $0.id == setup.goal.id })
        #expect(resumedGoal.operation == setup.goal); #expect(resumedGoal.state == .queued); #expect(resumedGoal.attempts == 1)
        #expect(try reopened.pending().first?.id == setup.food.id)
        #expect(try reopened.foodUndoRequested(setup.food.id))
        #expect(try reopened.healthProgress(setup.scope.id)?.anchor == Data([2]))
    }
    @Test func failedHealthSavePreservesMixedStateAndRestartRetriesSamePageOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hub.sqlite")
        var setup: Setup!, before: Checkpoint!, page: HealthImportPage!
        let sample = try h.sample(800, metric: .stepCount, at: h.time.addingTimeInterval(120))
        do {
            let store = try HubStore(url: url, owner: "synthetic@example.test")
            setup = try self.setup(store); before = try checkpoint(store, setup: setup)
            page = h.page(setup.scope, anchor: Data([2]), next: 3, added: [sample], deleted: [setup.samples[0].id])
            store.healthCommitCheck = { throw CocoaError(.fileWriteUnknown) }
            #expect(throws: CocoaError.self) { try store.ingestHealth(page, synthetic: true) }
            #expect(try checkpoint(store, setup: setup) == before)
            #expect(try store.healthRecord(sample.id) == nil)
        }
        var savedIDs: [String] = []
        do {
            let reopened = try HubStore(url: url, owner: "synthetic@example.test")
            #expect(try checkpoint(reopened, setup: setup) == before)
            #expect(try reopened.ingestHealth(page, synthetic: true) != nil)
            let after = try reopened.pending()
            #expect(after.count == before.queue.count + 1); #expect(after.last?.id == page.id)
            #expect(try reopened.ingestHealth(page, synthetic: true) == nil)
            #expect(try reopened.pending().map(\.id) == after.map(\.id))
            #expect(try reopened.healthRecord(setup.samples[0].id)?.removed == true)
            #expect(try reopened.healthRecord(sample.id)?.sample == sample)
            #expect(try reopened.healthProgress(setup.scope.id)?.anchor == Data([3]))
            #expect(try reopened.foodUndoRequested(setup.food.id))
            #expect(try reopened.rows() == before.rows)
            #expect(try reopened.healthStatistics(metric: .stepCount, date: day) == before.statistic)
            savedIDs = try reopened.pending().map(\.id)
        }
        let restored = try HubStore(url: url, owner: "synthetic@example.test")
        #expect(try restored.ingestHealth(page, synthetic: true) == nil)
        #expect(try restored.pending().map(\.id) == savedIDs)
        #expect(try restored.healthProgress(setup.scope.id)?.anchor == Data([3]))
        #expect(try restored.healthRecord(sample.id)?.sample == sample)
        #expect(try restored.foodUndoRequested(setup.food.id))

    }
}
