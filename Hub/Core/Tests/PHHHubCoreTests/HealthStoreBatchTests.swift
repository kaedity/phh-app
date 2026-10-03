import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct HealthStoreBatchTests {
    let h = HealthTests()

    func samples(_ count: Int, metric: HealthMetric = .bodyMass, offset: Int = 0) throws -> [HealthSample] {
        try (offset..<(offset + count)).map { index in
            try h.sample(metric == .stepCount ? 10 : 60, metric: metric,
                at: h.time.addingTimeInterval(Double(index)),
                id: String(format: "00000000-0000-4000-a000-%012d", index + 1))
        }
    }

    @Test func syntheticSQLitePageOf500FetchesOnlyItsUUIDsAndKeepsTheReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HubStore(url: root.appendingPathComponent("hub.sqlite"), owner: "synthetic@example.test")
        let scope = try h.scope(), added = try samples(500), page = h.page(scope, added: added)
        try store.registerHealthScope(scope)
        var keyCounts: [Int] = []
        store.healthLocalFetchCheck = { keyCounts.append($0) }
        let start = ContinuousClock.now
        let delta = try store.ingestHealth(page, synthetic: true)
        let elapsed = start.duration(to: .now).components
        let measurement: [String: Any] = ["scenario": "synthetic_sqlite_initial_500", "samples": added.count,
            "health_local_fetches": keyCounts.count, "requested_keys": keyCounts.reduce(0, +),
            "largest_fetch": keyCounts.max() ?? 0,
            "elapsed_ms": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15]
        print("HEALTH_PAGE_MEASUREMENT " + String(decoding: try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys]), as: UTF8.self))
        #expect(keyCounts == [500])
        #expect(delta?.added == added)
        #expect(try store.healthProgress(scope.id)?.anchor == Data([1]))
        #expect(try store.healthRecords(metric: .bodyMass, limit: 500).totalCount == 500)
        #expect(try store.pending().map(\.id) == [page.id])
        keyCounts = []
        #expect(try store.ingestHealth(page, synthetic: true) == nil)
        #expect(keyCounts == [500])
        #expect(try store.pending().map(\.id) == [page.id])
    }

    @Test func mixedPageReusesExistingObjectsAndUnknownTombstonesNeverResurrect() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(), history = try h.scope(.history)
        let original = try samples(500), replacement = try samples(250, offset: 500), unknown = try samples(125, offset: 1000)
        try store.registerHealthScope(scope); try store.registerHealthScope(history)
        let first = h.page(scope, added: original)
        try store.ingestHealth(first, synthetic: true)
        var keyCounts: [Int] = []; store.healthLocalFetchCheck = { keyCounts.append($0) }
        let deleted = Array(original.prefix(125)).map(\.id) + unknown.map(\.id)
        let mixed = h.page(scope, anchor: Data([1]), next: 2, added: replacement, deleted: deleted)
        store.healthCommitCheck = { throw CocoaError(.fileWriteUnknown) }
        #expect(throws: CocoaError.self) { try store.ingestHealth(mixed, synthetic: true) }
        #expect(keyCounts == [500])
        #expect(try store.healthRecords(metric: .bodyMass, limit: 500).totalCount == 500)
        #expect(try store.healthRecords(metric: .bodyMass, limit: 500, includeRemoved: true).totalCount == 500)
        #expect(try store.healthProgress(scope.id)?.anchor == Data([1])); #expect(try store.pending().map(\.id) == [first.id])
        keyCounts = []; store.healthCommitCheck = nil
        let delta = try store.ingestHealth(mixed, synthetic: true)
        #expect(keyCounts == [500]); #expect(delta?.added == replacement); #expect(delta?.deletedIDs == deleted)
        #expect(try store.healthRecords(metric: .bodyMass, limit: 500).totalCount == 625)
        #expect(try store.healthRecords(metric: .bodyMass, limit: 500, includeRemoved: true).totalCount == 875)
        #expect(try store.pending().map(\.id) == [first.id, mixed.id])
        keyCounts = []
        let overlap = h.page(history, added: Array(original.prefix(125)) + unknown)
        let overlapDelta = try store.ingestHealth(overlap, synthetic: true)
        #expect(keyCounts == [250]); #expect(overlapDelta?.added.isEmpty == true)
        #expect(try store.healthRecords(metric: .bodyMass, limit: 500).totalCount == 625)
        #expect(try store.pending().map(\.id) == [first.id, mixed.id])
        #expect(try store.healthProgress(history.id)?.anchor == Data([1]))
        #expect(try store.ingestHealth(mixed, synthetic: true) == nil)
        #expect(try store.pending().count == 2)
    }

    @Test func invalidPageLimitOrUUIDRejectsBeforeTheHealthLocalFetch() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(), valid = try samples(1)
        try store.registerHealthScope(scope)
        var keyCounts: [Int] = []; store.healthLocalFetchCheck = { keyCounts.append($0) }
        let tooMany = h.page(scope, added: try samples(501))
        let invalidDelete = h.page(scope, deleted: ["not-a-uuid"])
        var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h.page(scope, added: valid))) as! [String: Any]
        var added = body["added"] as! [[String: Any]]; added[0]["id"] = "not-a-uuid"; body["added"] = added
        let invalidAdded = try JSONSerialization.data(withJSONObject: body)
        // HealthSampleの既存decoderは不正UUIDを取込前に拒否します。
        #expect(throws: HealthFailure.invalidValue) { try JSONDecoder().decode(HealthImportPage.self, from: invalidAdded) }
        for page in [tooMany, invalidDelete] {
            #expect(throws: HealthFailure.invalidValue) { try store.ingestHealth(page, synthetic: true) }
        }
        #expect(keyCounts.isEmpty); #expect(try store.healthProgress(scope.id)?.anchor == nil)
        #expect(try store.healthRecords(metric: .bodyMass).totalCount == 0); #expect(try store.pending().isEmpty)
        let duplicate = h.page(scope, added: [valid[0], valid[0]])
        #expect(throws: HealthFailure.invalidValue) { try store.ingestHealth(duplicate, synthetic: true) }
        #expect(try store.healthProgress(scope.id)?.anchor == nil); #expect(try store.pending().isEmpty)
    }

    @Test func batchSaveFailureRollsBackRawAnchorStatisticsDirtyAndOutboxTogether() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(metric: .stepCount)
        try store.registerHealthScope(scope)
        let date = HealthDates.local(h.time), old = try HealthDailyStatistics(metric: .stepCount, date: date, value: 120, measuredAt: h.time)
        let seed = HealthImportPage(scopeID: scope.id, expectedAnchor: nil, nextAnchor: Data([1]), added: [], deletedIDs: [], hasMore: false, receivedAt: h.time, statistics: [old])
        var keyCounts: [Int] = []; store.healthLocalFetchCheck = { keyCounts.append($0) }
        try store.ingestHealth(seed, synthetic: true)
        #expect(keyCounts.isEmpty)
        let initialDirty = try #require(store.healthDirtyDays(metric: .stepCount).first)
        try store.commitHealthStatistics(old, dirty: initialDirty, synthetic: true)
        let pendingBefore = try store.pending().map(\.id)
        let newest = try HealthDailyStatistics(metric: .stepCount, date: date, value: 140, measuredAt: h.time.addingTimeInterval(60))
        let page = HealthImportPage(scopeID: scope.id, expectedAnchor: Data([1]), nextAnchor: Data([2]), added: try samples(499, metric: .stepCount), deletedIDs: [], hasMore: false, receivedAt: h.time, statistics: [newest])
        store.healthCommitCheck = { throw CocoaError(.fileWriteUnknown) }
        #expect(throws: CocoaError.self) { try store.ingestHealth(page, synthetic: true) }
        #expect(keyCounts == [499]); #expect(try store.healthRecords(metric: .stepCount).totalCount == 0)
        #expect(try store.healthProgress(scope.id)?.anchor == Data([1]))
        #expect(try store.healthStatistics(metric: .stepCount, date: date) == old)
        #expect(try store.healthDirtyDays(metric: .stepCount).isEmpty); #expect(try store.pending().map(\.id) == pendingBefore)
        store.healthCommitCheck = nil; keyCounts = []
        try store.ingestHealth(page, synthetic: true)
        #expect(keyCounts == [499]); #expect(try store.healthRecords(metric: .stepCount, limit: 500).totalCount == 499)
        #expect(try store.healthProgress(scope.id)?.anchor == Data([2])); #expect(try store.healthStatistics(metric: .stepCount, date: date) == newest)
        let dirty = try store.healthDirtyDays(metric: .stepCount)
        #expect(dirty.count == 1); #expect(try store.pending().map(\.id) == pendingBefore + [page.id])
        #expect(try store.ingestHealth(page, synthetic: true) == nil)
        #expect(try store.healthDirtyDays(metric: .stepCount) == dirty); #expect(try store.pending().map(\.id) == pendingBefore + [page.id])
    }
}
