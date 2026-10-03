import Foundation
import CryptoKit
import CoreData
import Testing
@testable import PHHHubCore
@Suite @MainActor struct HubCoreTests {
    struct Fixture: Decodable { var operation: HubOperation; var receipt: Receipt; var initial: Delta; var latest: Delta; var removal: HubOperation; var removalReceipt: Receipt; var removed: Delta }
    func fixture() throws -> Fixture { try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Bundle.module.url(forResource: "server-fixture", withExtension: "json")!)) }
    @Test func liveQueueHeadPreservesBlockedOrderAndSeesDeletionAndAppend() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test")
        #expect(try store.pending().first == nil)
        try store.enqueue(f.operation); try store.enqueue(f.removal)
        try store.deferOperation(f.operation.id, state: .conflict, message: "test", retryAt: .distantFuture)
        #expect(try store.pending().first?.id == f.operation.id)
        #expect(try store.pending().first?.state == .conflict)
        try store.discardRejected(f.operation.id)
        #expect(try store.pending().first?.id == f.removal.id)
        try store.enqueue(f.operation)
        #expect(try store.pending().map(\.id) == [f.removal.id, f.operation.id])
        #expect(try store.pending().first?.id == f.removal.id)
    }
    @Test func queueHeadFetchBenchmark() throws {
        guard ProcessInfo.processInfo.environment["PHH_QUEUE_BENCHMARK"] == "1" else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try fixture(), sqlite = ProcessInfo.processInfo.environment["PHH_QUEUE_BENCHMARK_SQLITE"] == "1"
        let store = try HubStore(url: sqlite ? dir.appendingPathComponent("hub.sqlite") : nil, owner: "synthetic@example.test")
        var operations: [HubOperation] = []
        for index in 0..<500 { var op = f.operation; op.operation_id = String(format: "00000000-0000-4000-a000-%012d", 100_000 + index); operations.append(op) }
        try store.enqueueBatch(operations)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<100 { #expect(try store.pending().first?.id == operations.first?.id) }
        let all = start.duration(to: clock.now)
        let encoding = JSONEncoder(); encoding.outputFormatting = [.sortedKeys]
        let inputHash = SHA256.hash(data: try encoding.encode(operations)).map { String(format: "%02x", $0) }.joined()
        print("PHH_QUEUE_BENCHMARK input_sha256=\(inputHash) backend=\(sqlite ? "sqlite" : "memory") rows=500 reads=100 pending=\(all)")
        #expect(try store.pending().count == 500)
    }
    func corruptOutbox(_ store: HubStore, id: String, field: String, value: Any) throws {
        // Deliberate storage corruption without a production test hook.
        let container = try #require(Mirror(reflecting: store).children.first(where: { $0.label == "container" })?.value as? NSPersistentContainer)
        let request = NSFetchRequest<NSManagedObject>(entityName: "Outbox")
        request.predicate = NSPredicate(format: "key == %@", id)
        let row = try #require(container.viewContext.fetch(request).first)
        row.setValue(value, forKey: field); try container.viewContext.save()
    }
    @Test func malformedHeadOrLaterRowStopsBeforeAnyTransmissionEvenAfterCacheWarmup() async throws {
        for later in [false, true] {
            for field in ["payload", "state"] {
                let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"), transport = PausedQueueTransport()
                try store.enqueue(f.operation); try store.enqueue(f.removal)
                #expect(try store.pending().count == 2)
                try corruptOutbox(store, id: later ? f.removal.id : f.operation.id, field: field,
                  value: field == "payload" ? Data("{".utf8) : "broken-state")
                await SyncEngine(store: store, transport: transport).synchronize(date: "2026-10-03")
                #expect(transport.sent.isEmpty)
                #expect(try store.cursor == 0)
            }
        }
    }
    @Test func changedPayloadInvalidatesDecodedOperationCache() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test")
        try store.enqueue(f.operation); #expect(try store.pending().first?.operation == f.operation)
        var replacement = f.removal; replacement.operation_id = f.operation.id
        try corruptOutbox(store, id: f.operation.id, field: "payload", value: JSONEncoder().encode(replacement))
        #expect(try store.pending().first?.operation == replacement)
    }
    @Test func sqliteRestartKeepsBlockedHeadAndLiveDeletionAppendOrder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hub.sqlite"), f = try fixture()
        var store: HubStore? = try HubStore(url: url, owner: "synthetic@example.test")
        try store!.enqueue(f.operation); try store!.enqueue(f.removal)
        try store!.deferOperation(f.operation.id, state: .conflict, message: "test", retryAt: .distantFuture)
        store = nil
        let reopened = try HubStore(url: url, owner: "synthetic@example.test"), transport = PausedQueueTransport()
        await SyncEngine(store: reopened, transport: transport).synchronize(date: "2026-10-03", forceQueued: true)
        #expect(transport.sent.isEmpty)
        #expect(try reopened.pending().map(\.id) == [f.operation.id, f.removal.id])
        try reopened.discardRejected(f.operation.id)
        try reopened.enqueue(f.operation)
        await SyncEngine(store: reopened, transport: transport).synchronize(date: "2026-10-03")
        #expect(transport.sent.map(\.id) == [f.removal.id, f.operation.id])
        #expect(try reopened.pending().isEmpty)
    }
    @Test func suspendedSendSeesUnsentCancellationAppendAndOneCompensatingFoodRemoval() async throws {
        let store = try HubStore(owner: "synthetic@example.test"), f = try FoodHubTests().fixture()
        try FoodHubTests().ready(store)
        let a = try FoodWireOperation(.init(expectedRevision: 0, meal: f.meal), environment: hubEnvironment).hubOperation()
        var b = a; b.operation_id = UUID().uuidString
        var c = a; c.operation_id = UUID().uuidString
        try store.enqueueBatch([a, b])
        let transport = PausedQueueTransport(); transport.pauseFirst = true
        let engine = SyncEngine(store: store, transport: transport)
        let task = Task { await engine.synchronize(date: "2026-10-03") }
        await transport.waitUntilPaused()
        try store.undoFoodAddition(b); try store.enqueue(c); try store.undoFoodAddition(a)
        transport.release(); await task.value
        #expect(transport.sent.count == 3)
        #expect(transport.sent.prefix(2).map(\.id) == [a.id, c.id])
        let cancellation = try #require(transport.sent.last)
        #expect(cancellation.action == "remove_food_meal")
        #expect(cancellation.entity_id == a.entity_id)
        #expect(!transport.sent.contains(where: { $0.id == b.id }))
        #expect(try store.pending().isEmpty)
        await engine.synchronize(date: "2026-10-03")
        #expect(transport.sent.count == 3)
    }
    @Test func scriptExecutionEnvelopeDoesNotCommitAnUnfinishedOrAmbiguousResult() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"); try store.enqueue(f.operation)
        let receipt = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.receipt))
        let good = try JSONSerialization.data(withJSONObject: ["done": true, "response": ["result": receipt]])
        let accepted = try HubScriptResponse.decode(Receipt.self, from: good); try accepted.validate(for: f.operation)
        let pending = try JSONSerialization.data(withJSONObject: ["done": false])
        #expect(throws: HubError.remote("EXECUTION_PENDING")) { _ = try HubScriptResponse.decode(Receipt.self, from: pending) }
        let ambiguous = try JSONSerialization.data(withJSONObject: ["done": true, "response": ["result": receipt], "error": ["details": [["errorMessage": "BUSY"]]]])
        #expect(throws: HubError.invalidResponse) { _ = try HubScriptResponse.decode(Receipt.self, from: ambiguous) }
        #expect(try store.pending().count == 1)
    }
    @Test func scriptFailuresSeparateReauthorizationRetryAndMalformedResponses() throws {
        func error(_ code: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["done": true, "error": ["details": [["errorMessage": code]]]]) }
        #expect(throws: HubError.authentication) { _ = try HubScriptResponse.decode(Receipt.self, from: error("OWNER_REQUIRED")) }
        #expect(throws: HubError.remote("BUSY")) { _ = try HubScriptResponse.decode(Receipt.self, from: error("BUSY")) }
        #expect(throws: HubError.remote("BUSY")) { _ = try HubScriptResponse.decode(Receipt.self, from: error("Error: BUSY")) }
        #expect(throws: HubError.invalidResponse) { _ = try HubScriptResponse.decode(Receipt.self, from: error("Error: BUSY extra private content")) }
        #expect(throws: HubError.invalidResponse) { _ = try HubScriptResponse.decode(Receipt.self, from: Data("{\"done\":true,\"response\":{\"result\":{}}}".utf8)) }
    }
    @Test func failureDiagnosticsStoreKnownCodesWithoutPrivateMessageOrURL() {
        #expect(syncFailureCode(HubError.remote("BUSY")) == "BUSY")
        #expect(syncFailureCode(HubError.remote("private body: https://example.test/token")) == "REMOTE_OTHER")
        #expect(syncFailureCode(URLError(.timedOut)) == "NETWORK_-1001")
        #expect(syncFailureCode(HubError.invalidResponse) == "INVALID_RESPONSE")
    }
    @Test func actualServerContractAndCoalescing() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test")
        try f.operation.validate(); try f.receipt.validate(for: f.operation); try store.apply(f.latest)
        #expect(try store.cursor == f.latest.next_cursor)
        #expect(try store.rows(table: "Meals").first?.revision == 2)
        #expect(try store.rows(table: "IntakeNutrients").first(where: { $0.values["nutrient_id"] == .string("kcal") })?.values["value"] == .number(200))
        #expect(try store.rows(table: "TrainingSets").count == 1)
        #expect(try store.rows(table: "TrainingSets").first?.values["rpe"] == .null)
    }
    @Test func removalAndNullPayload() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test")
        try f.removal.validate(); try f.removalReceipt.validate(for: f.removal); try store.apply(f.latest); try store.apply(f.removed)
        #expect(try store.rows(table: "Meals").first?.active == false)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.removal)) as! [String: Any]
        #expect(json["payload"] is NSNull)
        #expect(try store.rows(table: "DailySummary").first?.values["kcal"] == .number(0))
    }
    @Test func multiplePendingAndReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hub.sqlite"), f = try fixture()
        var store: HubStore? = try HubStore(url: url, owner: "synthetic@example.test")
        try store!.enqueue(f.operation); try store!.enqueue(f.removal); try store!.enqueue(f.operation)
        try store!.apply(f.latest); store = nil
        let reopened = try HubStore(url: url, owner: "synthetic@example.test")
        #expect(try reopened.pending().map(\.id) == [f.operation.id, f.removal.id])
        #expect(try reopened.pending().first?.id == f.operation.id)
        try reopened.finish(f.receipt, operation: f.operation)
        #expect(try reopened.pending().first?.id == f.removal.id)
        #expect(try reopened.cursor == f.latest.next_cursor)
        #expect(try reopened.rows(table: "Meals").first?.revision == 2)
        #expect(throws: HubError.accountChanged) { _ = try HubStore(url: url, owner: "other@example.test") }
    }
    @Test func corruptPageDoesNotAdvanceOrPartiallyApply() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"); try store.apply(f.initial)
        var bad = f.latest; bad.changes = Array(bad.changes.dropFirst(f.initial.next_cursor)); bad.changes[bad.changes.count - 1].record["revision"] = .number(-1)
        #expect(throws: HubError.invalidResponse) { try store.apply(bad) }
        #expect(try store.cursor == f.initial.next_cursor)
        #expect(try store.rows(table: "Meals").first?.revision == 1)
        #expect(try store.rows(table: "TrainingSets").isEmpty)
    }
    @Test func sameRevisionDifferentBodyRollsBackWholePage() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"); try store.apply(f.initial)
        var bad = f.latest; bad.changes = Array(bad.changes.dropFirst(f.initial.next_cursor))
        let index = bad.changes.firstIndex(where: { $0.change.table_name == "DailySummary" })!
        bad.changes[index].record["revision"] = .number(1); bad.changes[index].record["kcal"] = .number(999); bad.changes[index].change.revision = 1; bad.changes[index].change.indexed_revision = 1
        #expect(throws: HubError.invalidResponse) { try store.apply(bad) }
        #expect(try store.cursor == f.initial.next_cursor)
        #expect(try store.rows(table: "Meals").first?.revision == 1)
    }
    @Test func environmentGenerationAndCursorReject() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test")
        var bad = f.initial; bad.environment = "PHH_TEST"; #expect(throws: HubError.invalidResponse) { try store.apply(bad) }
        bad = f.initial; bad.generation = 2; #expect(throws: HubError.invalidResponse) { try store.apply(bad) }
        bad = f.initial; bad.changes[0].change.change_number = 2; #expect(throws: HubError.invalidResponse) { try store.apply(bad) }
        #expect(try store.cursor == 0)
    }
    @Test func nullAndZeroRemainDistinctAndInvalidNumbersReject() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"); try store.apply(f.initial)
        #expect(try store.rows(table: "IntakeNutrients").first(where: { $0.values["nutrient_id"] == .string("fat_g") })?.values["value"] == .number(0))
        var row = try store.rows(table: "IntakeNutrients")[0]; row.values["value"] = .null; try Schema.validate(row)
        row.values["value"] = .number(-1); #expect(throws: HubError.invalidResponse) { try Schema.validate(row) }
        row.values["value"] = .number(.infinity); #expect(throws: HubError.invalidResponse) { try Schema.validate(row) }
        row.values["revision"] = .number(.nan); #expect(throws: HubError.invalidResponse) { try Schema.validate(row) }
    }
    @Test func forgedReceiptKeepsPending() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"); try store.enqueue(f.operation)
        var receipt = f.receipt; receipt.operation_id = UUID().uuidString
        #expect(throws: HubError.invalidResponse) { try store.finish(receipt, operation: f.operation) }
        #expect(try store.pending().count == 1)
    }
    @Test func lostResponseIsReadBeforeResending() async throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"), transport = Mock(f)
        try store.enqueue(f.operation); let engine = SyncEngine(store: store, transport: transport)
        transport.committed = true
        await engine.synchronize(date: "2026-10-01")
        #expect(transport.submissions == 0); #expect(try store.pending().isEmpty); #expect(try store.cursor == f.initial.next_cursor)
    }
    @Test func offlinePreservesQueueAndStableIDThenRecovers() async throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"), transport = Mock(f)
        try store.enqueue(f.operation); let engine = SyncEngine(store: store, transport: transport)
        transport.failure = URLError(.notConnectedToInternet)
        let now = Date(); await engine.synchronize(date: "2026-10-01", now: now)
        #expect(try store.pending().first?.id == f.operation.id); #expect(try store.pending().first?.state == .queued)
        transport.failure = nil; await engine.synchronize(date: "2026-10-01", now: now.addingTimeInterval(10))
        #expect(transport.submissions == 1); #expect(try store.pending().isEmpty)
    }
    @Test func responseLostAfterCommitAndDatabaseRestartRecoversOneOperation() async throws {
        let f = try fixture(), path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("hub.sqlite")
        let transport = Mock(f), now = Date()
        var store: HubStore? = try HubStore(url: path, owner: "synthetic@example.test")
        try store!.enqueue(f.operation); transport.loseResponse = true
        await SyncEngine(store: store!, transport: transport).synchronize(date: "2026-10-01", now: now)
        #expect(transport.submissions == 1); #expect(try store!.pending().first?.id == f.operation.id); #expect(try store!.cursor == 0)
        store = nil
        let restarted = try HubStore(url: path, owner: "synthetic@example.test")
        await SyncEngine(store: restarted, transport: transport).synchronize(date: "2026-10-01", now: now.addingTimeInterval(10))
        #expect(transport.submissions == 1); #expect(try restarted.pending().isEmpty); #expect(try restarted.cursor == f.initial.next_cursor)
    }
    @Test func onlyRejectedOperationsCanBeDiscardedAndConfirmedRowsStay() throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"); try store.apply(f.initial); try store.enqueue(f.operation)
        #expect(throws: HubError.invalidOperation) { try store.discardRejected(f.operation.id) }
        try store.deferOperation(f.operation.id, state: .authentication, message: "test", retryAt: .now)
        #expect(throws: HubError.invalidOperation) { try store.discardRejected(f.operation.id) }
        try store.deferOperation(f.operation.id, state: .conflict, message: "test", retryAt: .now)
        try store.discardRejected(f.operation.id)
        #expect(try store.pending().isEmpty); #expect(try store.rows(table: "Meals").count == 1); #expect(try store.cursor == f.initial.next_cursor)
    }
    @Test func manualSyncRetriesQueuedOperationBeforeBackoffDeadline() async throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"), transport = Mock(f), now = Date()
        try store.enqueue(f.operation); let engine = SyncEngine(store: store, transport: transport)
        transport.failure = URLError(.notConnectedToInternet)
        await engine.synchronize(date: "2026-10-01", now: now)
        #expect(try store.pending().first!.retryAt > now)
        transport.failure = nil
        await engine.synchronize(date: "2026-10-01", now: now.addingTimeInterval(1))
        #expect(transport.submissions == 0); #expect(try store.pending().first?.id == f.operation.id)
        await engine.synchronize(date: "2026-10-01", now: now.addingTimeInterval(1), forceQueued: true)
        #expect(transport.submissions == 1); #expect(try store.pending().isEmpty)
    }
    @Test func forcedSyncDoesNotResendAuthenticationConflictOrInvalidOperations() async throws {
        let f = try fixture()
        for state in [PendingState.authentication, .conflict, .invalid] {
            let store = try HubStore(owner: "synthetic@example.test"), transport = Mock(f)
            try store.enqueue(f.operation); try store.deferOperation(f.operation.id, state: state, message: "test", retryAt: .distantFuture)
            await SyncEngine(store: store, transport: transport).synchronize(date: "2026-10-01", forceQueued: true)
            #expect(transport.submissions == 0); #expect(try store.pending().first?.state == state)
        }
    }
    @Test func authenticationAndConflictDoNotAutomaticallyResubmit() async throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"), transport = Mock(f)
        try store.enqueue(f.operation); let engine = SyncEngine(store: store, transport: transport)
        transport.failure = HubError.authentication; await engine.synchronize(date: "2026-10-01")
        #expect(try store.pending().first?.state == .authentication)
        transport.failure = nil; transport.rejection = "REVISION_CONFLICT"; try store.resumeAuthentication(); await engine.synchronize(date: "2026-10-01")
        #expect(try store.pending().first?.state == .conflict)
        await engine.synchronize(date: "2026-10-01"); #expect(transport.submissions == 1)
    }
    @Test func interruptedDeltaRetriesSameCursorWithoutResendingCommittedOperation() async throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"), transport = Mock(f)
        try store.enqueue(f.operation); transport.deltaFailures = [URLError(.networkConnectionLost), HubError.remote("BUSY")]
        var waits: [UInt64] = []
        let engine = SyncEngine(store: store, transport: transport, retryWait: { waits.append($0) })
        await engine.synchronize(date: "2026-10-01")
        #expect(engine.message == "同期しました"); #expect(transport.submissions == 1)
        #expect(transport.deltaCursors == [0, 0, 0]); #expect(waits == [1_000_000_000, 20_000_000_000])
        #expect(engine.timing.metrics.first { $0.stage == .retryWait }?.calls == 2)
        #expect(engine.timing.metrics.first { $0.stage == .deltaFetch }?.calls == 3)
        #expect(engine.timing.metrics.first { $0.stage == .operationCommit }?.calls == 1)
        #expect(try store.cursor == f.initial.next_cursor); #expect(try store.pending().isEmpty)
    }
    @Test func deltaRetriesAreBoundedAndUnsafeFailuresKeepPreviousCursor() async throws {
        let f = try fixture()
        for error in [HubError.invalidResponse, .authentication, .remote("unknown")] {
            let store = try HubStore(owner: "synthetic@example.test"), transport = Mock(f)
            transport.committed = true; transport.deltaFailures = [error]; var waits = 0
            let engine = SyncEngine(store: store, transport: transport, retryWait: { _ in waits += 1 })
            await engine.synchronize(date: "2026-10-01")
            #expect(waits == 0); #expect(transport.deltaCursors == [0]); #expect(try store.cursor == 0)
        }
        let store = try HubStore(owner: "synthetic@example.test"), transport = Mock(f)
        transport.deltaFailures = [URLError(.networkConnectionLost), URLError(.networkConnectionLost), URLError(.networkConnectionLost)]
        var waits = 0; let engine = SyncEngine(store: store, transport: transport, retryWait: { _ in waits += 1 })
        await engine.synchronize(date: "2026-10-01")
        #expect(waits == 2); #expect(transport.deltaCursors.count == 3); #expect(engine.lastFailureCode == "NETWORK_-1005")
        #expect(try store.cursor == 0); #expect(transport.submissions == 0)
    }
    @Test func duplicateConcurrentSyncDoesNotSendTwice() async throws {
        let f = try fixture(), store = try HubStore(owner: "synthetic@example.test"), transport = Mock(f)
        try store.enqueue(f.operation); let engine = SyncEngine(store: store, transport: transport)
        let task = Task { await engine.synchronize(date: "2026-10-01") }; await Task.yield(); await engine.synchronize(date: "2026-10-01"); await task.value
        #expect(transport.submissions == 1); #expect(try store.pending().isEmpty)
    }
}
@MainActor private final class Mock: HubTransport {
    let fixture: HubCoreTests.Fixture; var connected = true; var committed = false; var submissions = 0; var failure: Error?; var rejection: String?; var loseResponse = false
    init(_ fixture: HubCoreTests.Fixture) { self.fixture = fixture }
    func result(_ operation: HubOperation) async throws -> Receipt {
        await Task.yield(); if let failure { throw failure }; if committed { return fixture.receipt }
        return Receipt(environment: nil, operation_id: operation.id, status: "not_found", retryable: true)
    }
    func submit(_ operation: HubOperation) async throws -> Receipt {
        submissions += 1
        if let rejection { return Receipt(environment: hubEnvironment, operation_id: operation.id, status: "rejected", error_code: rejection, entity_ids: [], revisions: [], retryable: false) }
        committed = true
        if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
        return fixture.receipt
    }
    func processIntake(date: String) async throws {}
    var deltaFailures: [Error] = []; var deltaCursors: [Int?] = []
    func delta(_ query: HubQuery) async throws -> Delta {
        deltaCursors.append(query.after); if !deltaFailures.isEmpty { throw deltaFailures.removeFirst() }
        if !committed { var page = fixture.initial; page.changes = []; page.snapshot_revision = 0; page.next_cursor = 0; page.has_more = false; return page }
        if query.after == fixture.initial.next_cursor { var page = fixture.initial; page.changes = []; return page }
        return fixture.initial
    }
}

@MainActor private final class PausedQueueTransport: HubTransport {
    var connected = true, pauseFirst = false
    var sent: [HubOperation] = []
    private var paused = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { resume?.resume(); resume = nil }
    func resolve(_ operation: HubOperation) async throws -> Receipt {
        sent.append(operation)
        if pauseFirst && sent.count == 1 {
            await withCheckedContinuation { continuation in
                resume = continuation; paused = true; waiting?.resume(); waiting = nil
            }
        }
        return Receipt(environment: hubEnvironment, operation_id: operation.id, status: "committed",
          entity_ids: [operation.entity_id], revisions: [operation.expected_revision + 1], retryable: false)
    }
    func result(_ operation: HubOperation) async throws -> Receipt { throw HubError.invalidOperation }
    func submit(_ operation: HubOperation) async throws -> Receipt { throw HubError.invalidOperation }
    func processIntake(date: String) async throws {}
    func delta(_ query: HubQuery) async throws -> Delta {
        var page = Delta(schema_version: 1, environment: hubEnvironment, generation: 1,
          snapshot_revision: query.after ?? 0, changes: [], next_cursor: query.after ?? 0, has_more: false)
        page.food_contract = 1; return page
    }
}
