import Foundation
import CryptoKit
import Testing
@testable import PHHHubCore

@Suite @MainActor struct SyncQueueBatchTests {
    let h = HealthTests()
    let day = "2026-10-03"

    func ready(_ store: HubStore) throws { try store.apply(QueueRemote.emptyDelta()) }
    func healthOperations(_ count: Int, samplesPerOperation: Int = 125) throws -> [HubOperation] {
        try (0..<count).map { index in
            let added = try (0..<samplesPerOperation).map { ordinal in
                try h.sample(id: String(format: "00000000-0000-4000-a000-%012d", index * samplesPerOperation + ordinal + 1))
            }
            return try HubOperation(health: HealthCloudDelta(id: String(format: "00000000-0000-4000-b000-%012d", index + 1),
                metric: .bodyMass, added: added, deletedIDs: [], affectedDates: [HealthDates.local(h.time)]), synthetic: true)
        }
    }
    func digest(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func meal() -> HubOperation { HubOperation(action: "confirm_meal", meal: SyntheticMeal(date: day)) }
    func food() throws -> HubOperation {
        try FoodWireOperation(.init(expectedRevision: 0, meal: FoodHubTests().fixture().meal), environment: hubEnvironment).hubOperation()
    }

    @Test func syntheticHealthQueuePreservesIDsReceiptsAndOneCommitWithBoundedReads() async throws {
        let store = try HubStore(owner: "synthetic@example.test"), remote = QueueRemote()
        try ready(store)
        let operations = try healthOperations(40); try store.enqueueBatch(operations)
        var metadataReads = 0; store.pendingMetadataFetchCheck = { metadataReads += 1 }
        let engine = SyncEngine(store: store, transport: remote), start = ContinuousClock.now
        await engine.synchronize(date: day)
        let elapsed = start.duration(to: .now).components, queue = try #require(engine.timing.metrics.first { $0.stage == .queueRead })
        let expectedReceipts = operations.map { $0.id + "|" + $0.entity_id + "|1" }
        let observedReceipts = remote.receipts.map { $0.operation_id + "|" + ($0.entity_ids?.first ?? "") + "|" + String($0.revisions?.first ?? 0) }
        let measurement: [String: Any] = ["scenario": "synthetic_40_health_operations_125_samples", "operations": operations.count,
            "raw_samples": 5000, "queue_reads": queue.calls, "queue_items_decoded": queue.itemCount, "metadata_point_fetches": metadataReads,
            "queue_read_ms": queue.elapsedSeconds * 1000,
            "elapsed_ms": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
            "resolved_count": remote.resolved.count, "committed_count": remote.committed.count,
            "ids_match": remote.resolved == operations.map(\.id), "payloads_match": remote.submitted == operations,
            "receipts_match": expectedReceipts == observedReceipts, "receipt_digest": digest(observedReceipts)]
        print("SYNC_QUEUE_MEASUREMENT " + String(decoding: try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys]), as: UTF8.self))
        #expect(queue.calls == 3); #expect(queue.itemCount == 40); #expect(metadataReads == 40)
        #expect(remote.resolved == operations.map(\.id)); #expect(remote.submitted == operations)
        #expect(expectedReceipts == observedReceipts); #expect(remote.committed.count == operations.count)
        #expect(engine.timing.metrics.first { $0.stage == .operationCommit }?.calls == operations.count)
        #expect(try store.pending().isEmpty); #expect(engine.message == "同期しました")
    }

    @Test func receiptCreatedFoodUndoIsReadInTheNextBatchAfterEarlierQueuedOperations() async throws {
        let store = try HubStore(owner: "synthetic@example.test"), remote = QueueRemote()
        try ready(store)
        let first = try food(), second = meal(); try store.enqueueBatch([first, second])
        remote.onResult = { operation in if operation.id == first.id { try store.undoFoodAddition(first) } }
        let engine = SyncEngine(store: store, transport: remote); await engine.synchronize(date: day)
        #expect(remote.submitted.count == 3); #expect(remote.submitted.prefix(2) == [first, second])
        let cancellation = try #require(remote.submitted.last)
        #expect(cancellation.action == "remove_food_meal"); #expect(cancellation.entity_id == first.entity_id)
        #expect(cancellation.expected_revision == 1); #expect(cancellation.id != first.id)
        #expect(remote.resolved == [first.id, second.id, cancellation.id]); #expect(remote.committed.count == 3)
        #expect(engine.timing.metrics.first { $0.stage == .queueRead }?.calls == 4)
        #expect(try !store.foodUndoRequested(first.id)); #expect(try store.pending().isEmpty)
    }

    @Test func awaitingTransportAcceptsNewOperationsAndSkipsCanceledUnsentSnapshotRows() async throws {
        let store = try HubStore(owner: "synthetic@example.test"), remote = QueueRemote(), gate = QueueGate()
        try ready(store)
        let first = meal(), canceled = try food(), remaining = meal(), appended = meal()
        try store.enqueueBatch([first, canceled, remaining])
        remote.onResult = { operation in if operation.id == first.id { await gate.pause() } }
        let engine = SyncEngine(store: store, transport: remote), task = Task { await engine.synchronize(date: day) }
        await gate.waitUntilPaused()
        try store.undoFoodAddition(canceled); try store.enqueue(appended)
        gate.resume(); await task.value
        #expect(remote.resolved == [first.id, remaining.id, appended.id])
        #expect(remote.submitted == [first, remaining, appended]); #expect(remote.committed.count == 3)
        #expect(try store.pending().isEmpty); #expect(engine.message == "同期しました")
    }

    @Test func canceledAndReenqueuedSameIDUsesFreshContentAndFreshSequence() async throws {
        let store = try HubStore(owner: "synthetic@example.test"), remote = QueueRemote(), gate = QueueGate()
        try ready(store)
        let first = meal(), old = try food(), tail = meal(), original = try #require(old.foodMeal)
        var replacement = old
        replacement.foodMeal = try FoodMeal(id: original.id, revision: original.revision, date: day,
            slot: original.slot == "夕食" ? "朝食" : "夕食", items: original.items,
            presetID: original.presetID, presetRevision: original.presetRevision)
        try store.enqueueBatch([first, old, tail])
        #expect(throws: HubError.invalidOperation) { try store.enqueue(replacement) }
        remote.onResult = { operation in if operation.id == first.id { await gate.pause() } }
        let engine = SyncEngine(store: store, transport: remote), task = Task { await engine.synchronize(date: day) }
        await gate.waitUntilPaused()
        try store.undoFoodAddition(old); try store.enqueue(replacement)
        gate.resume(); await task.value
        #expect(remote.resolved == [first.id, tail.id, replacement.id])
        #expect(remote.submitted == [first, tail, replacement]); #expect(!remote.submitted.contains(old))
        #expect(try store.pending().isEmpty)
    }

    @Test func healthCapabilityAndConsentStayHeldWithoutBlockingIndependentMeals() async throws {
        let store = try HubStore(owner: "synthetic@example.test"), remote = QueueRemote()
        var health = try healthOperations(2, samplesPerOperation: 1)
        health[1].synthetic = false
        let independent = meal(); try store.enqueueBatch(health + [independent])
        let engine = SyncEngine(store: store, transport: remote)
        await engine.synchronize(date: day)
        #expect(remote.submitted == [independent]); #expect(try store.pending().map(\.id) == health.map(\.id))
        #expect(try store.healthContract == 1)
        await engine.synchronize(date: day)
        #expect(remote.submitted == [independent, health[0]]); #expect(try store.pending().map(\.id) == [health[1].id])
        try store.setHealthUploadPolicy(HealthUploadPolicy(allowedMetrics: [.bodyMass], from: HealthDates.local(h.time), authorizedAt: h.time))
        await engine.synchronize(date: day)
        #expect(remote.submitted == [independent] + health); #expect(try store.pending().isEmpty)

        let planningStore = try HubStore(owner: "synthetic@example.test"), planningRemote = QueueRemote()
        let planning = try PlanningStoreTests().ruleOperation(), later = meal(); try planningStore.enqueueBatch([planning, later])
        let planningEngine = SyncEngine(store: planningStore, transport: planningRemote)
        await planningEngine.synchronize(date: day)
        #expect(planningRemote.submitted.isEmpty); #expect(try planningStore.pending().map(\.id) == [planning.id, later.id])
        await planningEngine.synchronize(date: day)
        #expect(planningRemote.submitted == [planning, later]); #expect(try planningStore.pending().isEmpty)
    }

    @Test func failedHeadAndAwaitingFutureStateNeverAutomaticallyResubmit() async throws {
        for state in [PendingState.authentication, .conflict, .invalid] {
            let store = try HubStore(owner: "synthetic@example.test"), remote = QueueRemote()
            try ready(store)
            let first = meal(), second = meal(); try store.enqueueBatch([first, second])
            try store.deferOperation(first.id, state: state, message: "synthetic", retryAt: .distantFuture)
            await SyncEngine(store: store, transport: remote).synchronize(date: day, forceQueued: true)
            #expect(remote.resolved.isEmpty); #expect(try store.pending().map(\.id) == [first.id, second.id])
            #expect(try store.pending().first?.state == state); #expect(try store.pending().last?.attempts == 0)

            let futureStore = try HubStore(owner: "synthetic@example.test"), futureRemote = QueueRemote(), gate = QueueGate()
            try ready(futureStore)
            let current = meal(), future = meal(), tail = meal(); try futureStore.enqueueBatch([current, future, tail])
            futureRemote.onResult = { operation in if operation.id == current.id { await gate.pause() } }
            let engine = SyncEngine(store: futureStore, transport: futureRemote), task = Task { await engine.synchronize(date: day, forceQueued: true) }
            await gate.waitUntilPaused()
            try futureStore.deferOperation(future.id, state: state, message: "synthetic", retryAt: .distantFuture)
            gate.resume(); await task.value
            #expect(futureRemote.submitted == [current]); #expect(futureRemote.resolved == [current.id])
            #expect(try futureStore.pending().map(\.id) == [future.id, tail.id])
            #expect(try futureStore.pending().first?.state == state); #expect(try futureStore.pending().last?.attempts == 0)
        }
    }

    @Test func authenticationBusyBackoffConflictAndLostReplyKeepLaterOperationsQueued() async throws {
        let now = Date(timeIntervalSince1970: 1790953200)
        for failure in [HubError.authentication, .remote("BUSY")] {
            let store = try HubStore(owner: "synthetic@example.test"), remote = QueueRemote(); try ready(store)
            let first = meal(), second = meal(); try store.enqueueBatch([first, second]); remote.resultFailure = failure
            let engine = SyncEngine(store: store, transport: remote); await engine.synchronize(date: day, now: now)
            #expect(remote.resolved == [first.id]); #expect(remote.submitted.isEmpty)
            #expect(try store.pending().map(\.id) == [first.id, second.id]); #expect(try store.pending().last?.attempts == 0)
            remote.resultFailure = nil
            if failure == .authentication { try store.resumeAuthentication() }
            else {
                #expect(try store.pending().first!.retryAt > now)
                await engine.synchronize(date: day, now: now.addingTimeInterval(1))
                #expect(remote.submitted.isEmpty)
            }
            await engine.synchronize(date: day, now: now.addingTimeInterval(1), forceQueued: true)
            #expect(remote.submitted == [first, second]); #expect(try store.pending().isEmpty)
        }
        let conflicted = try HubStore(owner: "synthetic@example.test"), rejecting = QueueRemote(); try ready(conflicted)
        let conflict = meal(), tail = meal(); try conflicted.enqueueBatch([conflict, tail]); rejecting.rejectionCode = "REVISION_CONFLICT"
        let conflictEngine = SyncEngine(store: conflicted, transport: rejecting)
        await conflictEngine.synchronize(date: day, now: now)
        #expect(rejecting.submitted == [conflict]); #expect(try conflicted.pending().first?.state == .conflict)
        await conflictEngine.synchronize(date: day, now: now, forceQueued: true)
        #expect(rejecting.submitted == [conflict]); #expect(try conflicted.pending().last?.attempts == 0)

        let lost = try HubStore(owner: "synthetic@example.test"), losing = QueueRemote(); try ready(lost)
        let first = meal(), second = meal(); try lost.enqueueBatch([first, second]); losing.loseResponseID = first.id
        let lostEngine = SyncEngine(store: lost, transport: losing); await lostEngine.synchronize(date: day, now: now)
        #expect(losing.submitted == [first]); #expect(try lost.pending().map(\.id) == [first.id, second.id])
        await lostEngine.synchronize(date: day, now: now, forceQueued: true)
        #expect(losing.submitted == [first, second]); #expect(losing.resolved == [first.id, first.id, second.id])
        #expect(losing.committed.count == 2); #expect(try lost.pending().isEmpty)
    }

    @Test func canceledSynchronizationKeepsIDsAndLaterRowsUnattemptedThenRecoversOnce() async throws {
        let store = try HubStore(owner: "synthetic@example.test"), remote = QueueRemote(), gate = QueueGate(); try ready(store)
        let first = meal(), second = meal(); try store.enqueueBatch([first, second])
        remote.onResult = { operation in if operation.id == first.id { await gate.pause() } }
        let engine = SyncEngine(store: store, transport: remote), task = Task { await engine.synchronize(date: day) }
        await gate.waitUntilPaused(); task.cancel(); gate.resume(); await task.value
        #expect(!engine.busy); #expect(remote.submitted.isEmpty); #expect(remote.resolved == [first.id])
        #expect(try store.pending().map(\.id) == [first.id, second.id]); #expect(try store.pending().last?.attempts == 0)
        remote.onResult = nil; await engine.synchronize(date: day, forceQueued: true)
        #expect(remote.submitted == [first, second]); #expect(remote.committed.count == 2); #expect(try store.pending().isEmpty)
    }
}

@MainActor private final class QueueRemote: HubTransport {
    var connected = true
    var resolved: [String] = []
    var submitted: [HubOperation] = []
    var committed: Set<String> = []
    var receipts: [Receipt] = []
    var onResult: (@MainActor (HubOperation) async throws -> Void)?
    var resultFailure: Error?
    var rejectionCode: String?
    var loseResponseID: String?
    static func emptyDelta() -> Delta {
        Delta(schema_version: 1, environment: hubEnvironment, generation: 1, health_contract: 1,
            planning_contract: 1, food_contract: 1, snapshot_revision: 0, changes: [], next_cursor: 0, has_more: false)
    }
    func receipt(_ operation: HubOperation) -> Receipt {
        Receipt(environment: hubEnvironment, operation_id: operation.id, status: "committed",
            entity_ids: [operation.entity_id], revisions: [operation.expected_revision + 1], retryable: false)
    }
    func result(_ operation: HubOperation) async throws -> Receipt {
        resolved.append(operation.id)
        try await onResult?(operation); try Task.checkCancellation()
        if let resultFailure { throw resultFailure }
        if committed.contains(operation.id) { return receipt(operation) }
        return Receipt(environment: nil, operation_id: operation.id, status: "not_found", retryable: true)
    }
    func submit(_ operation: HubOperation) async throws -> Receipt {
        submitted.append(operation)
        if let rejectionCode {
            return Receipt(environment: hubEnvironment, operation_id: operation.id, status: "rejected", error_code: rejectionCode, retryable: false)
        }
        committed.insert(operation.id)
        let result = receipt(operation); receipts.append(result)
        if loseResponseID == operation.id { loseResponseID = nil; throw URLError(.networkConnectionLost) }
        return result
    }
    func processIntake(date: String) async throws {}
    func delta(_ query: HubQuery) async throws -> Delta { Self.emptyDelta() }
}

@MainActor private final class QueueGate {
    private var paused: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            paused = continuation; arrived?.resume(); arrived = nil
        }
    }
    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { arrived = $0 }
    }
    func resume() { paused?.resume(); paused = nil }
}
