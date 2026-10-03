import Foundation
import Testing
@testable import PHHHubCore

@Suite struct AutoSleepTests {
    let received = Date(timeIntervalSince1970: 1_791_000_000)
    func normalize(_ entries: [AutoSleepEntry], dictionary: AutoSleepDictionary = .timeAsleep,
        date: String = "2026-10-03", id: String = UUID().uuidString, at: Date? = nil) throws -> AutoSleepNormalization {
        try AutoSleepNormalizer.normalize(id: id, dictionary: dictionary, targetDate: date, timeZoneID: "Asia/Tokyo",
            sourceRevision: "synthetic-v1", receivedAt: at ?? received, entries: entries)
    }
    var night: [AutoSleepEntry] { [.init(key: "睡眠", value: .number(7.75), unit: "h"),
        .init(key: "スタート", value: .text("2026-10-02T23:00:00+09:00"), unit: "ISO8601"),
        .init(key: "Until", value: .text("2026-10-03T07:00:00+09:00"), unit: "ISO8601")] }
    @Test func decimalHoursAndJapaneseKeysPreserveRawValuesAndUTCWakeDate() throws {
        let result = try normalize(night), record = try #require(result.record)
        #expect(record.actualSleepSeconds == 27_900); #expect(record.originalDictionary == night)
        #expect(record.interval?.start == Date(timeIntervalSince1970: 1_790_949_600))
        #expect(record.interval?.end.timeIntervalSince(record.interval!.start) == 28_800)
        #expect(record.targetDate == "2026-10-03" && record.metrics[0].id == "autosleep.timeAsleep.Sleep")
        try record.validate()
    }
    @Test func independentRingMetricsNeverBecomeAppleSleepStagesOrPercentRatios() throws {
        let result = try normalize([.init(key: "深い", value: .number(1.5), unit: "h"),
            .init(key: "良質な睡眠%", value: .number(95), unit: "%"), .init(key: "心拍数", value: .number(55), unit: "bpm")], dictionary: .sleepRings)
        let metrics = try #require(result.record).metrics
        #expect(metrics[0].id == "autosleep.sleepRings.Deep" && metrics[0].value == 1.5 && metrics[0].unit == "h")
        #expect(metrics[1].value == 95 && metrics[1].unit == "%")
        #expect(metrics[2].value == 55 && metrics[2].unit == "bpm")
    }
    @Test func unknownKeysAndUnspecifiedUnitsRemainVisibleWithoutInventingValues() throws {
        let entries: [AutoSleepEntry] = [.init(key: "睡眠", value: .number(7.75)),
            .init(key: "未実証項目", value: .text("synthetic"), unit: "unknown")]
        let result = try normalize(entries), record = try #require(result.record)
        #expect(record.actualSleepSeconds == nil); #expect(record.originalDictionary == entries)
        #expect(record.metrics[0].value == nil && record.metrics[0].unit == nil)
        #expect(result.issues.map(\.kind) == [.missingUnit, .unsupportedKey])
    }
    @Test func missingSleepAndExplicitZeroAreDifferentAndSignedBalanceIsRetained() throws {
        let missing = try normalize([.init(key: "Sleep", value: .missing, unit: "h")])
        let zero = try normalize([.init(key: "Sleep", value: .number(0), unit: "h"), .init(key: "Balance", value: .number(-1), unit: "h")])
        #expect(missing.record?.actualSleepSeconds == nil); #expect(zero.record?.actualSleepSeconds == 0)
        #expect(zero.record?.metrics[1].value == -1)
    }
    @Test func wrongUnitsTypesNegativeOrNonfiniteInputsRefuseImportAndPreserveOriginal() throws {
        for entry in [AutoSleepEntry(key: "Sleep", value: .number(7), unit: "min"),
            .init(key: "Sleep", value: .text("7.75"), unit: "h"), .init(key: "Sleep", value: .number(-1), unit: "h"),
            .init(key: "Sleep", value: .number(.infinity), unit: "h"), .init(key: "Sleep", value: .number(.nan), unit: "h")] {
            let result = try normalize([entry]); #expect(!result.accepted && result.record == nil)
            #expect(result.originalDictionary == [entry] && result.issues.first?.blocksImport == true)
            let retained = try JSONDecoder().decode(AutoSleepNormalization.self, from: JSONEncoder().encode(result)); #expect(retained == result)
        }
    }
    @Test func aliasesDuplicatesAndInvalidIntervalsCannotSilentlyOverwrite() throws {
        let entries: [AutoSleepEntry] = [.init(key: "睡眠", value: .number(7), unit: "h"), .init(key: "Sleep", value: .number(8), unit: "h")]
        let duplicate = try normalize(entries); #expect(!duplicate.accepted && duplicate.issues.first?.kind == .duplicateKey)
        #expect(duplicate.originalDictionary.count == 2)
        #expect(!(try normalize(night, date: "2026-10-02")).accepted)
        let reversed = [night[0], .init(key: "Start", value: .text("2026-10-03T08:00:00+09:00"), unit: "ISO8601"), night[2]]
        #expect(!(try normalize(reversed)).accepted)
        let tooLong = [AutoSleepEntry(key: "Sleep", value: .number(9), unit: "h"), night[1], night[2]]
        #expect(!(try normalize(tooLong)).accepted)
        #expect(!(try normalize([.init(key: "Start", value: .text("2026-10-03T01:00:00"), unit: "ISO8601")])).accepted)
    }
    @Test func readinessVerifiedAliasesAndUnverifiedRatingRemainSourceMetrics() throws {
        let entries: [AutoSleepEntry] = [.init(key: "基準心拍変動", value: .number(60), unit: "ms"), .init(key: "星", value: .number(3), unit: "count"),
            .init(key: "起きている時の基準心拍数", value: .number(55), unit: "bpm"), .init(key: "評価", value: .text("架空評価"), unit: "text")]
        let record = try #require(try normalize(entries, dictionary: .readiness).record)
        #expect(record.metrics.map(\.canonicalKey) == ["BaselineHRV", "Stars", "BaselineWakingBPM", "observed_rating"])
        #expect(record.metrics.last?.original.value == .text("架空評価")); #expect(record.actualSleepSeconds == nil)
        let decoded = try JSONDecoder().decode(AutoSleepRecord.self, from: JSONEncoder().encode(record)); #expect(decoded == record); try decoded.validate()
    }
    @Test func operationReplayIsIdempotentAndChangedContentKeepsPreviousRecord() throws {
        let key = UUID().uuidString, first = try #require(try normalize(night, id: key).record)
        var ledger = try AutoSleepLedger(); #expect(try ledger.apply(first) == first)
        let replay = try #require(try normalize(night, id: key, at: received.addingTimeInterval(10)).record)
        #expect(try ledger.apply(replay) == first && ledger.records.count == 1)
        let before = ledger, changed = try #require(try normalize([.init(key: "Sleep", value: .number(1), unit: "h")], id: key).record)
        #expect(throws: AutoSleepFailure.operationIDReused) { try ledger.apply(changed) }; #expect(ledger == before)
        ledger = try JSONDecoder().decode(AutoSleepLedger.self, from: JSONEncoder().encode(ledger)); #expect(try ledger.apply(replay) == first)
    }
}
