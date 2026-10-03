import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct HealthServerContractTests {
    struct Fixture: Decodable { let operations: [HubOperation]; let receipts: [Receipt]; let delta: Delta }
    @Test func gasRowsAndReceiptsApplyWithMatchingHealthSchemaWithoutPreparations() throws {
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Bundle.module.url(forResource: "health-server-fixture", withExtension: "json")!))
        let hub = try HubStore(owner: "synthetic@example.test")
        for (operation, receipt) in zip(f.operations, f.receipts) {
            try operation.validate(); try receipt.validate(for: operation); try hub.enqueue(operation)
            #expect(try JSONDecoder().decode(HubOperation.self, from: JSONEncoder().encode(operation)) == operation)
            try hub.finish(receipt, operation: operation)
        }
        try hub.apply(f.delta)
        #expect(try hub.healthContract == 1); #expect(try hub.pending().isEmpty)
        #expect(try hub.rows(table: "HealthDaily").count == 2)
        #expect(try hub.rows(table: "HealthDaily").first { $0.values["metric"]?.text == "stepCount" }?.values["value"] == .number(0))
        #expect(try hub.rows(table: "HealthArchives").count == 2)
        #expect(!Schema.syncTables.contains("HealthPreparations"))
        var bad = f.delta; bad.health_contract = 2
        #expect(throws: HubError.invalidResponse) { try hub.apply(bad) }
        #expect(try hub.cursor == f.delta.next_cursor)
    }
    @Test func combinedItemAndEncodedByteCapsRejectBeforeQueueing() throws {
        let h = HealthTests(), stat = try HealthDailyStatistics(metric: .stepCount, date: HealthDates.local(h.time), value: 0, measuredAt: h.time)
        let ids = (0..<500).map { String(format: "00000000-0000-4000-a000-%012d", $0) }
        let valid = HealthCloudDelta(id: UUID().uuidString, metric: .stepCount, added: [], deletedIDs: Array(ids.prefix(499)), affectedDates: [stat.date], statistics: [stat])
        #expect(try HubOperation(health: valid, synthetic: true).health == valid)
        let tooMany = HealthCloudDelta(id: UUID().uuidString, metric: .stepCount, added: [], deletedIDs: ids, affectedDates: [stat.date], statistics: [stat])
        #expect(throws: HubError.invalidOperation) { try HubOperation(health: tooMany, synthetic: true) }
        let source = try HealthSource(id: String(repeating: "a", count: 500), name: String(repeating: "架", count: 500), device: String(repeating: "d", count: 500))
        let samples = try ids.prefix(110).map { try HealthSample(id: $0, metric: .bodyMass, source: source, start: h.time, end: h.time, value: 60, unit: "kg") }
        let large = HealthCloudDelta(id: UUID().uuidString, metric: .bodyMass, added: samples, deletedIDs: [], affectedDates: [HealthDates.local(h.time)])
        let hub = try HubStore(owner: "synthetic@example.test")
        #expect(throws: HubError.invalidOperation) { try hub.enqueue(HubOperation(health: large, synthetic: true)) }
        #expect(try hub.pending().isEmpty)
    }
}
