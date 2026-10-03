import Foundation
import CoreData
import Testing
@testable import PHHHubCore

@Suite @MainActor struct HealthPageValidationTests {
    @Test func pagesRejectTheSameInvalidStoredPayloadAsIndividualReads() throws {
        let h = HealthTests(), scope = try h.scope(), sample = try h.sample()
        let store = try HubStore(owner: "synthetic@example.test")
        try store.registerHealthScope(scope)
        try store.ingestHealth(h.page(scope, added: [sample]), synthetic: true)
        let container = try #require(Mirror(reflecting: store).children.first { $0.label == "container" }?.value as? NSPersistentContainer)
        let request = NSFetchRequest<NSManagedObject>(entityName: "HealthLocal")
        request.predicate = NSPredicate(format: "key == %@", sample.id)
        let row = try #require(container.viewContext.fetch(request).first)
        let original = try #require(row.value(forKey: "payload") as? Data)
        let anchor = try store.healthProgress(scope.id)?.anchor
        let pending = try store.pending().map(\.id)
        for defect in ["negativeValue", "wrongID", "missingSample", "missingPayload"] {
            var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var fields = try #require(json["sample"] as? [String: Any])
            if defect == "negativeValue" { fields["value"] = -1 }
            if defect == "wrongID" { fields["id"] = "00000000-0000-0000-0000-000000000099" }
            json["sample"] = fields
            if defect == "missingSample" { json.removeValue(forKey: "sample") }
            row.setValue(defect == "missingPayload" ? nil : try JSONSerialization.data(withJSONObject: json), forKey: "payload")
            #expect(throws: (any Error).self) { try store.healthRecord(sample.id) }
            #expect(throws: (any Error).self) { try store.healthRecords(metric: .bodyMass) }
            #expect(try store.healthProgress(scope.id)?.anchor == anchor)
            #expect(try store.pending().map(\.id) == pending)
        }
        row.setValue(original, forKey: "payload")
        #expect(try store.healthRecords(metric: .bodyMass).records.first?.sample == sample)
    }
    @Test func validPagesAndKnownOrUnknownTombstonesSurviveRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let h = HealthTests(), scope = try h.scope(), a = try h.sample(), b = try h.sample(61, at: h.time.addingTimeInterval(60))
        let unknown = "00000000-0000-0000-0000-000000000088", url = root.appendingPathComponent("hub.sqlite")
        do {
            let store = try HubStore(url: url, owner: "synthetic@example.test")
            try store.registerHealthScope(scope)
            try store.ingestHealth(h.page(scope, added: [a,b]), synthetic: true)
            try store.ingestHealth(h.page(scope, anchor: Data([1]), next: 2, deleted: [a.id,unknown]), synthetic: true)
        }
        let store = try HubStore(url: url, owner: "synthetic@example.test")
        #expect(try store.healthRecords(metric: .bodyMass).records.map(\.sample) == [b])
        let first = try store.healthRecords(metric: .bodyMass, limit: 1, includeRemoved: true)
        #expect(first.totalCount == 3); #expect(first.hasMore); #expect(first.records.first?.sample == b)
        let all = try store.healthRecords(metric: .bodyMass, includeRemoved: true).records
        #expect(all.contains(HealthLocalRecord(sample: a, removed: true)))
        #expect(all.contains(HealthLocalRecord(sample: nil, removed: true)))
        #expect(try store.healthRecords(metric: .bodyMass, offset: 3, limit: 1, includeRemoved: true).records.isEmpty)
    }


    @Test func rejectedStoredPageKeepsScreenHistoryAndRefreshState() throws {
        let h = HealthTests(), scope = try h.scope(), store = try HubStore(owner: "synthetic@example.test")
        let samples = try (0..<105).map { try h.sample(60 + Double($0)/100, at: h.time.addingTimeInterval(Double($0)*60)) }
        try store.registerHealthScope(scope); try store.ingestHealth(h.page(scope, added: samples), synthetic: true)
        let screen = try HealthScreenModel(store: store, date: HealthDates.local(h.time))
        let before = screen.weightSamples, date = screen.date, source = screen.selectedWeightSource
        let container = try #require(Mirror(reflecting: store).children.first { $0.label == "container" }?.value as? NSPersistentContainer)
        let request = NSFetchRequest<NSManagedObject>(entityName: "HealthLocal")
        request.predicate = NSPredicate(format: "key == %@", samples[0].id)
        let row = try #require(container.viewContext.fetch(request).first)
        let payload = try #require(row.value(forKey: "payload") as? Data)
        row.setValue(try JSONEncoder().encode(HealthLocalRecord(sample: nil, removed: false)), forKey: "payload")
        #expect(throws: HubError.invalidResponse) { try screen.loadMoreWeight() }
        #expect(screen.weightSamples == before); #expect(screen.weightTotalCount == 105); #expect(screen.hasMoreWeight)
        row.setValue(payload, forKey: "payload")
        request.predicate = NSPredicate(format: "key == %@", samples[104].id)
        let newest = try #require(container.viewContext.fetch(request).first)
        newest.setValue(try JSONEncoder().encode(HealthLocalRecord(sample: nil, removed: false)), forKey: "payload")
        #expect(throws: HubError.invalidResponse) { try screen.refresh(date: "2026-10-04") }
        #expect(screen.weightSamples == before); #expect(screen.date == date)
        #expect(screen.selectedWeightSource == source); #expect(screen.weightTotalCount == 105); #expect(screen.hasMoreWeight)
        #expect(screen.message == "取得内容を確認できません。前回の表示を保持しています。")
    }

}
