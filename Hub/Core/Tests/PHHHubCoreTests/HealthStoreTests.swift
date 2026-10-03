import Foundation
import CoreData
import Testing
@testable import PHHHubCore

@Suite @MainActor struct HealthStoreTests {
    let h = HealthTests()
    func emptyDelta() -> Delta { Delta(schema_version: 1, environment: hubEnvironment, generation: 1, health_contract: 1, snapshot_revision: 0, changes: [], next_cursor: 0, has_more: false) }
    @Test func existingThreeEntitySQLiteMigratesWithoutLosingCursorRowsOrQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("hub.sqlite"), op = HubOperation(action: "confirm_meal", meal: SyntheticMeal(date: "2026-10-01"))
        do {
            let old = NSPersistentContainer(name: "PersonalHealthHub", managedObjectModel: HubStore.makeModel(includeHealth: false))
            let d = NSPersistentStoreDescription(url: url); d.shouldAddStoreAsynchronously = false; old.persistentStoreDescriptions = [d]
            var failure: Error?; old.loadPersistentStores { _, error in failure = error }; if let failure { throw failure }
            for (key,value) in ["owner":"synthetic@example.test", "environment":hubEnvironment, "generation":"1", "cursor":"7", "sequence":"1"] {
                let row = NSEntityDescription.insertNewObject(forEntityName: "Meta", into: old.viewContext); row.setValue(key, forKey: "key"); row.setValue(value, forKey: "value")
            }
            let queued = NSEntityDescription.insertNewObject(forEntityName: "Outbox", into: old.viewContext)
            for (key,value) in ["key":op.id,"payload":try JSONEncoder().encode(op),"state":"queued","message":"同期待ち","retry":0.0,"attempts":2,"sequence":1] as [String:Any] { queued.setValue(value, forKey: key) }
            let row = NSEntityDescription.insertNewObject(forEntityName: "Record", into: old.viewContext)
            let values: [String:Cell] = ["id":.string(op.entity_id),"revision":.number(1)]
            for (key,value) in ["key":"Meals:" + op.entity_id,"table":"Meals","date":"2026-10-01","payload":try JSONEncoder().encode(values),"revision":1] as [String:Any] { row.setValue(value, forKey: key) }
            try old.viewContext.save(); for persistent in old.persistentStoreCoordinator.persistentStores { try old.persistentStoreCoordinator.remove(persistent) }
        }
        let upgraded = try HubStore(url: url, owner: "synthetic@example.test")
        #expect(try upgraded.cursor == 7); #expect(try upgraded.pending().first?.id == op.id); #expect(try upgraded.pending().first?.attempts == 2)
        #expect(try upgraded.rows(table: "Meals").first?.entityID == op.entity_id)
        let scope = try h.scope(); try upgraded.registerHealthScope(scope); try upgraded.ingestHealth(h.page(scope, added: [try h.sample()]), synthetic: true)
        #expect(try upgraded.pending().count == 2); #expect(try upgraded.cursor == 7)
    }
    @Test func oneSavePreservesSamplesAnchorAndCommonOutboxAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hub.sqlite"), scope = try h.scope(), sample = try h.sample(), page = h.page(scope, added: [sample])
        var store: HubStore? = try HubStore(url: url, owner: "synthetic@example.test")
        try store!.registerHealthScope(scope); try store!.ingestHealth(page, synthetic: true)
        #expect(try store!.pending().map(\.id) == [page.id]); store = nil
        let reopened = try HubStore(url: url, owner: "synthetic@example.test")
        #expect(try reopened.healthProgress(scope.id)?.anchor == Data([1])); #expect(try reopened.healthRecord(sample.id)?.sample == sample)
        #expect(try reopened.ingestHealth(page, synthetic: true) == nil); #expect(try reopened.pending().count == 1)
        #expect(try reopened.healthRecords(metric: .bodyMass).totalCount == 1)
        let changed = h.page(scope, added: [try h.sample()], id: page.id)
        #expect(throws: HealthFailure.pageIDReused) { try reopened.ingestHealth(changed, synthetic: true) }
    }
    @Test func injectedSaveFailureRollsBackEveryPieceAndSamePageRestarts() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(), sample = try h.sample(), page = h.page(scope, added: [sample])
        try store.registerHealthScope(scope); store.healthCommitCheck = { throw CocoaError(.fileWriteUnknown) }
        #expect(throws: CocoaError.self) { try store.ingestHealth(page, synthetic: true) }
        #expect(try store.healthProgress(scope.id)?.anchor == nil); #expect(try store.healthRecord(sample.id) == nil); #expect(try store.pending().isEmpty)
        store.healthCommitCheck = nil; try store.ingestHealth(page, synthetic: true)
        #expect(try store.healthProgress(scope.id)?.anchor == Data([1])); #expect(try store.pending().count == 1)
    }
    @Test func tombstoneScopesEmptyReadsAndPaginationRetainTruth() throws {
        let store = try HubStore(owner: "synthetic@example.test"), recent = try h.scope(), history = try h.scope(.history), sample = try h.sample()
        try store.registerHealthScope(recent); try store.registerHealthScope(history)
        let alias = try HealthQueryScope(deviceID: recent.deviceID, metric: recent.metric, phase: recent.phase, lowerBound: recent.lowerBound)
        #expect(throws: HealthFailure.invalidScope) { try store.registerHealthScope(alias) }
        try store.ingestHealth(h.page(recent, deleted: [sample.id]), synthetic: true)
        try store.ingestHealth(h.page(history, added: [sample]), synthetic: true)
        #expect(try store.healthRecord(sample.id)?.removed == true); #expect(try store.healthRecords(metric: .bodyMass).totalCount == 0)
        let a = try h.sample(), b = try h.sample(61, at: h.time.addingTimeInterval(60))
        try store.ingestHealth(h.page(recent, anchor: Data([1]), next: 2, added: [a,b]), synthetic: true)
        #expect(try store.healthRecords(metric: .bodyMass, limit: 1).records.first?.sample?.id == b.id)
        #expect(try store.healthRecords(metric: .bodyMass, limit: 1).hasMore == true)
        try store.markHealthReadFailure(recent.id, state: .temporaryFailure)
        #expect(try store.healthProgress(recent.id)?.anchor == Data([2]))
        try store.ingestHealth(h.page(recent, anchor: Data([2]), next: 3), synthetic: true)
        #expect(try store.healthProgress(recent.id)?.readState == .available); #expect(try store.healthRecords(metric: .bodyMass).totalCount == 2)
    }
    @Test func statisticsAndSampleAnchorCommitTogetherWithoutAddingRawSources() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(metric: .stepCount), a = try h.sample(100, metric: .stepCount), b = try h.sample(80, metric: .stepCount)
        try store.registerHealthScope(scope)
        let statistic = try HealthDailyStatistics(metric: .stepCount, date: HealthDates.local(h.time), value: 120, measuredAt: h.time)
        let page = HealthImportPage(scopeID: scope.id, expectedAnchor: nil, nextAnchor: Data([1]), added: [a,b], deletedIDs: [], hasMore: false, receivedAt: h.time, statistics: [statistic])
        try store.ingestHealth(page, synthetic: true)
        #expect(try store.healthStatistics(metric: .stepCount, date: statistic.date)?.value == 120)
        #expect(try store.pending().first?.operation.health?.statistics == [statistic]); #expect(try store.healthRecords(metric: .stepCount).totalCount == 2)
        let old = try HealthDailyStatistics(metric: .stepCount, date: statistic.date, value: nil, measuredAt: h.time.addingTimeInterval(-60))
        try store.ingestHealth(HealthImportPage(scopeID: scope.id, expectedAnchor: Data([1]), nextAnchor: Data([2]), added: [], deletedIDs: [], hasMore: false, receivedAt: h.time, statistics: [old]), synthetic: true)
        #expect(try store.healthStatistics(metric: .stepCount, date: statistic.date)?.value == 120)
    }
    @Test func explicitUnixWireAndConsentCannotAuthorizeUnrelatedData() throws {
        let sample = try h.sample(), delta = HealthCloudDelta(id: UUID().uuidString.lowercased(), metric: .bodyMass, added: [sample], deletedIDs: [], affectedDates: [HealthDates.local(h.time)])
        let op = try HubOperation(health: delta, synthetic: false), bytes = try JSONEncoder().encode(op)
        let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any], payload = json["payload"] as! [String: Any], added = payload["added"] as! [[String: Any]]
        #expect(added[0]["start_utc"] as? Double == h.time.timeIntervalSince1970); #expect(added[0]["start"] == nil)
        #expect(try JSONDecoder().decode(HubOperation.self, from: bytes) == op)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("anchor"))
        let store = try HubStore(owner: "synthetic@example.test"); try store.enqueue(op)
        #expect(try !store.canSendHealth(op)); try store.apply(emptyDelta()); #expect(try !store.canSendHealth(op))
        let policy = try HealthUploadPolicy(allowedMetrics: [.bodyMass], from: HealthDates.local(h.time), authorizedAt: h.time)
        try store.setHealthUploadPolicy(policy); #expect(try store.canSendHealth(op))
        let unknownDelete = HealthCloudDelta(id: UUID().uuidString.lowercased(), metric: .bodyMass, added: [], deletedIDs: [UUID().uuidString.lowercased()], affectedDates: [])
        #expect(policy.allows(unknownDelete)); #expect(!(try HealthUploadPolicy()).allows(unknownDelete))
        var meal = HubOperation(action: "confirm_meal", meal: SyntheticMeal(date: HealthDates.local(h.time))); meal.synthetic = false
        #expect(throws: HubError.invalidOperation) { try store.enqueue(meal) }
        var mixed = op; mixed.payload = SyntheticMeal(date: HealthDates.local(h.time))
        #expect(throws: HubError.invalidOperation) { try mixed.validate() }
    }
    @Test func heldHealthDoesNotBlockMealsAndLostResponseUsesSameOperationID() async throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(), page = h.page(scope, added: [try h.sample()])
        try store.registerHealthScope(scope); try store.ingestHealth(page, synthetic: false)
        let meal = HubOperation(action: "confirm_meal", meal: SyntheticMeal(date: HealthDates.local(h.time))); try store.enqueue(meal)
        let remote = HealthRemote(emptyDelta()), engine = SyncEngine(store: store, transport: remote)
        await engine.synchronize(date: HealthDates.local(h.time)); #expect(remote.submitted == [meal.id]); #expect(try store.pending().map(\.id) == [page.id])
        try store.setHealthUploadPolicy(HealthUploadPolicy(allowedMetrics: [.bodyMass], from: HealthDates.local(h.time), authorizedAt: h.time))
        remote.loseOnce = true; await engine.synchronize(date: HealthDates.local(h.time))
        #expect(try store.pending().count == 1); await engine.synchronize(date: HealthDates.local(h.time), forceQueued: true)
        #expect(try store.pending().isEmpty); #expect(remote.submitted.filter { $0 == page.id }.count == 1)
    }
    @Test func consentRevokedBeforeRestartHoldsHealthWhileMealsContinue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hub.sqlite"), scope = try h.scope(), sample = try h.sample()
        let page = h.page(scope, added: [sample])
        let meal = HubOperation(action: "confirm_meal", meal: SyntheticMeal(date: HealthDates.local(h.time)))
        do {
            let store = try HubStore(url: url, owner: "synthetic@example.test")
            try store.registerHealthScope(scope); try store.ingestHealth(page, synthetic: false)
            try store.apply(emptyDelta())
            try store.setHealthUploadPolicy(HealthUploadPolicy(allowedMetrics: [.bodyMass], from: HealthDates.local(h.time), authorizedAt: h.time))
            #expect(try store.canSendHealth(try #require(store.pending().first?.operation)))
            try store.setHealthUploadPolicy(HealthUploadPolicy())
            try store.enqueue(meal)
        }
        let reopened = try HubStore(url: url, owner: "synthetic@example.test")
        #expect(try reopened.healthUploadPolicy().allowedMetrics.isEmpty)
        let remote = HealthRemote(emptyDelta()), engine = SyncEngine(store: reopened, transport: remote)
        await engine.synchronize(date: HealthDates.local(h.time))
        #expect(remote.submitted == [meal.id])
        #expect(try reopened.pending().map(\.id) == [page.id])
        #expect(try reopened.healthRecord(sample.id)?.sample == sample)
        #expect(try reopened.healthProgress(scope.id)?.anchor == page.nextAnchor)
    }
    @Test func healthUploadWaitsForServerContractWithoutLosingOperation() async throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(), page = h.page(scope, added: [try h.sample()])
        try store.registerHealthScope(scope); try store.ingestHealth(page, synthetic: true)
        let remote = HealthRemote(emptyDelta()), engine = SyncEngine(store: store, transport: remote)
        #expect(try store.healthContract == 0)
        await engine.synchronize(date: HealthDates.local(h.time))
        #expect(remote.submitted.isEmpty); #expect(try store.pending().map(\.id) == [page.id]); #expect(try store.healthContract == 1)
        await engine.synchronize(date: HealthDates.local(h.time))
        #expect(remote.submitted == [page.id]); #expect(try store.pending().isEmpty)
    }
}
@MainActor private final class HealthRemote: HubTransport {
    var connected = true, loseOnce = false
    let page: Delta; var submitted: [String] = [], committed: Set<String> = []
    init(_ page: Delta) { self.page = page }
    func result(_ operation: HubOperation) async throws -> Receipt {
        Receipt(environment: hubEnvironment, operation_id: operation.id, status: committed.contains(operation.id) ? "committed" : "not_found", entity_ids: committed.contains(operation.id) ? [operation.entity_id] : nil, revisions: committed.contains(operation.id) ? [1] : nil, retryable: false)
    }
    func submit(_ operation: HubOperation) async throws -> Receipt {
        submitted.append(operation.id); committed.insert(operation.id)
        if loseOnce { loseOnce = false; throw URLError(.networkConnectionLost) }; return try await result(operation)
    }
    func processIntake(date: String) async throws {}
    func delta(_ query: HubQuery) async throws -> Delta { page }
}
