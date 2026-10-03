import Foundation
import Testing
@testable import PHHHubCore
@Suite @MainActor struct AutoSleepIntakeTests {
    let now = Date(timeIntervalSince1970: 1790953200)
    func delivery(_ json: String, id: String? = nil, at: Date? = nil, units: String = "{}") throws -> AutoSleepDelivery {
        try AutoSleepIntake.delivery(id: id, dictionary: .timeAsleep, targetDate: "2026-10-03", timeZoneID: "Asia/Tokyo", json: json, unitsJSON: units, receivedAt: at ?? now)
    }
    @Test func ordinaryDictionaryUsesVerifiedSleepHoursAndRetainsUnknownAndMissingUnits() throws {
        let item = try delivery(#"{"睡眠":7.75,"借金%":0,"預金%":null,"未知":{"x":true}}"#)
        #expect(item.normalization.record?.actualSleepSeconds == 27900)
        #expect(item.normalization.record?.metrics.first { $0.canonicalKey == "Debt %" }?.value == nil)
        #expect(item.normalization.issues.contains { $0.kind == .missingUnit }); #expect(item.normalization.issues.contains { $0.kind == .unsupportedKey })
        #expect(item.originalJSON.contains(#""未知":{"x":true}"#))
        let explicit = try delivery(#"{"睡眠":0,"借金%":0}"#, units: #"{"借金%":"%"}"#)
        #expect(explicit.normalization.record?.actualSleepSeconds == 0); #expect(explicit.normalization.record?.metrics.first { $0.canonicalKey == "Debt %" }?.value == 0)
    }
    @Test func invalidValueKeepsRawDiagnosticAndSameIDContentChangeIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let inbox = try AutoSleepInbox(url: root.appendingPathComponent("autosleep.json")), item = try delivery(#"{"睡眠":true}"#)
        #expect(item.normalization.record == nil); #expect(item.normalization.issues.contains { $0.kind == .invalidType })
        try inbox.receive(item); #expect(try inbox.deliveries().first?.originalJSON == item.originalJSON)
        #expect(throws: AutoSleepFailure.operationIDReused) { try inbox.receive(delivery(#"{"睡眠":1}"#, id: item.id)) }
        #expect(try inbox.deliveries().count == 1)
    }
    @Test func reorderedRetryAndReopenReturnFirstReceiptWithoutDuplicate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("autosleep.json"), first = try delivery(#"{"睡眠":7.75,"借金%":3}"#)
        let retry = try delivery(#"{"借金%":3,"睡眠":7.75}"#, at: now.addingTimeInterval(20))
        #expect(first.id == retry.id); try AutoSleepInbox(url: url).receive(first)
        let reopened = try AutoSleepInbox(url: url); #expect(try reopened.receive(retry) == first); #expect(try reopened.deliveries().count == 1)
        #expect(throws: Error.self) { try delivery("[]") }; #expect(throws: Error.self) { try delivery(#"{"睡眠":1}"#, units: #"{"睡眠":true}"#) }
    }
}
