import Foundation

/// AutoSleepの辞書値です。Appleの睡眠段階やHealthKit標本へ変換しません。
public enum AutoSleepValue: Codable, Equatable, Sendable {
    case number(Double), text(String), boolean(Bool), missing
    public static func == (lhs: AutoSleepValue, rhs: AutoSleepValue) -> Bool {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)): a == b || a.isNaN && b.isNaN
        case (.text(let a), .text(let b)): a == b
        case (.boolean(let a), .boolean(let b)): a == b
        case (.missing, .missing): true
        default: false
        }
    }
    private enum Key: String, CodingKey { case type, number, text, boolean, nonfinite }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "number":
            if let special = try c.decodeIfPresent(String.self, forKey: .nonfinite) {
                switch special { case "NaN": self = .number(.nan); case "Infinity": self = .number(.infinity); case "-Infinity": self = .number(-.infinity)
                default: throw DecodingError.dataCorruptedError(forKey: .nonfinite, in: c, debugDescription: "Invalid nonfinite diagnostic") }
            } else { self = .number(try c.decode(Double.self, forKey: .number)) }
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "boolean": self = .boolean(try c.decode(Bool.self, forKey: .boolean))
        case "missing": self = .missing
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Invalid AutoSleep scalar")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .number(let value):
            try c.encode("number", forKey: .type)
            if value.isFinite { try c.encode(value, forKey: .number) }
            else { try c.encode(value.isNaN ? "NaN" : value > 0 ? "Infinity" : "-Infinity", forKey: .nonfinite) }
        case .text(let value): try c.encode("text", forKey: .type); try c.encode(value, forKey: .text)
        case .boolean(let value): try c.encode("boolean", forKey: .type); try c.encode(value, forKey: .boolean)
        case .missing: try c.encode("missing", forKey: .type)
        }
    }
}
public struct AutoSleepEntry: Codable, Equatable, Sendable {
    public let key: String
    public let value: AutoSleepValue
    /// 受渡し側が明示した単位。欠落時に値や項目名から推定しません。
    public let unit: String?
    public init(key: String, value: AutoSleepValue, unit: String? = nil) {
        self.key = key; self.value = value; self.unit = unit
    }
}
public enum AutoSleepDictionary: String, Codable, Sendable { case timeAsleep, sleepRings, readiness }
public enum AutoSleepFailure: Error, Equatable { case invalidMetadata, operationIDReused }
public enum AutoSleepIssueKind: String, Codable, Sendable {
    case unsupportedKey, missingUnit, unsupportedUnit, invalidValue, invalidType, duplicateKey, incompleteInterval, invalidInterval, targetDateMismatch
}
public struct AutoSleepIssue: Codable, Equatable, Sendable {
    public let key: String
    public let kind: AutoSleepIssueKind
    public let blocksImport: Bool
}
public struct AutoSleepMetric: Codable, Equatable, Sendable {
    /// 名前空間を持つ独自指標です。DeepはAppleのasleepDeepと別の指標です。
    public let id: String
    public let canonicalKey: String
    public let original: AutoSleepEntry
    public let value: Double?
    public let unit: String?
}
public struct AutoSleepInterval: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) throws {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end >= start else { throw AutoSleepFailure.invalidMetadata }
        self.start = start; self.end = end
    }
}
public struct AutoSleepRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let dictionary: AutoSleepDictionary
    public let targetDate: String
    public let timeZoneID: String
    public let sourceRevision: String?
    public let receivedAt: Date
    public let interval: AutoSleepInterval?
    public let metrics: [AutoSleepMetric]
    public let originalDictionary: [AutoSleepEntry]
    public let issues: [AutoSleepIssue]
    public var actualSleepSeconds: Double? { metrics.first { $0.canonicalKey == "Sleep" && $0.unit == "s" }?.value }
    public func validate() throws {
        let normalized = try AutoSleepNormalizer.normalize(id: id, dictionary: dictionary, targetDate: targetDate,
            timeZoneID: timeZoneID, sourceRevision: sourceRevision, receivedAt: receivedAt, entries: originalDictionary)
        guard normalized.record == self else { throw AutoSleepFailure.invalidMetadata }
    }
    fileprivate func sameContent(as other: AutoSleepRecord) -> Bool {
        id == other.id && dictionary == other.dictionary && targetDate == other.targetDate && timeZoneID == other.timeZoneID
            && sourceRevision == other.sourceRevision && interval == other.interval && metrics == other.metrics
            && originalDictionary == other.originalDictionary && issues == other.issues
    }
}
public struct AutoSleepNormalization: Codable, Equatable, Sendable {
    public let record: AutoSleepRecord?
    public let originalDictionary: [AutoSleepEntry]
    public let issues: [AutoSleepIssue]
    public var accepted: Bool { record != nil }
}

public enum AutoSleepNormalizer {
    private static let aliases: [AutoSleepDictionary: [String: String]] = [
        .timeAsleep: ["Until":"Until", "借金%":"Debt %", "Debt %":"Debt %", "預金%":"Credit %", "Credit %":"Credit %",
            "睡眠":"Sleep", "Sleep":"Sleep", "残高":"Balance", "Balance":"Balance", "スタート":"Start", "Start":"Start", "達成率%":"Recharge%", "Recharge%":"Recharge%"],
        .sleepRings: ["良質な睡眠%":"Quality%", "Quality%":"Quality%", "深い%":"Deep%", "Deep%":"Deep%", "心拍数%":"bpm%", "bpm%":"bpm%",
            "睡眠%":"Sleep%", "Sleep%":"Sleep%", "深い":"Deep", "Deep":"Deep", "睡眠の評価":"SleepRating", "SleepRating":"SleepRating",
            "睡眠":"Sleep", "Sleep":"Sleep", "心拍数":"bpm", "bpm":"bpm", "良質な睡眠":"Quality", "Quality":"Quality"],
        .readiness: ["基準心拍変動":"BaselineHRV", "BaselineHRV":"BaselineHRV", "星":"Stars", "Stars":"Stars", "心拍変動":"HRV", "HRV":"HRV",
            "心拍数":"bpm", "bpm":"bpm", "起きている時の基準心拍数":"BaselineWakingBPM", "BaselineWakingBPM":"BaselineWakingBPM", "評価":"observed_rating"]
    ]
    // Sleep=hはDESIGN5.1の確認済み規則。他の値は入口で単位を明示した場合だけ扱います。
    private static func units(_ key: String) -> Set<String> {
        if ["Start", "Until"].contains(key) { return ["ISO8601"] }
        if ["Sleep", "Quality", "Deep", "Balance"].contains(key) { return ["h"] }
        if key.contains("%") { return ["%"] }
        if ["bpm", "BaselineWakingBPM"].contains(key) { return ["bpm"] }
        if ["HRV", "BaselineHRV"].contains(key) { return ["ms"] }
        if key == "Stars" { return ["count"] }
        return ["count", "score", "text"]
    }
    private static func instant(_ text: String) -> Date? {
        guard text.range(of: #"(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]; return f.date(from: text)
    }
    private static func day(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func normalize(id: String, dictionary: AutoSleepDictionary, targetDate: String, timeZoneID: String,
        sourceRevision: String? = nil, receivedAt: Date, entries: [AutoSleepEntry]) throws -> AutoSleepNormalization {
        try FoodRules.id(id); try FoodRules.date(targetDate)
        guard let zone = TimeZone(identifier: timeZoneID), receivedAt.timeIntervalSince1970.isFinite,
              sourceRevision.map({ !$0.isEmpty && $0.count <= 200 }) ?? true, entries.count <= 200 else { throw AutoSleepFailure.invalidMetadata }
        var issues: [AutoSleepIssue] = [], metrics: [AutoSleepMetric] = [], used = Set<String>(), dates: [String: Date] = [:]
        func issue(_ key: String, _ kind: AutoSleepIssueKind, blocking: Bool = true) { issues.append(.init(key: key, kind: kind, blocksImport: blocking)) }
        for entry in entries {
            guard !entry.key.isEmpty, entry.key.count <= 200 else { issue(entry.key, .invalidValue); continue }
            let canonical = aliases[dictionary]![entry.key]
            let identity = canonical ?? "unsupported:" + entry.key
            guard used.insert(identity).inserted else { issue(entry.key, .duplicateKey); continue }
            if case .number(let number) = entry.value, !number.isFinite { issue(entry.key, .invalidValue); continue }
            guard let key = canonical else { issue(entry.key, .unsupportedKey, blocking: false); continue }
            let metricID = "autosleep." + dictionary.rawValue + "." + key
            if entry.value == .missing { metrics.append(.init(id: metricID, canonicalKey: key, original: entry, value: nil, unit: nil)); continue }
            guard let unit = entry.unit else { issue(entry.key, .missingUnit, blocking: false); metrics.append(.init(id: metricID, canonicalKey: key, original: entry, value: nil, unit: nil)); continue }
            guard units(key).contains(unit) else { issue(entry.key, .unsupportedUnit); continue }
            if ["Start", "Until"].contains(key) {
                guard case .text(let raw) = entry.value, let date = instant(raw) else { issue(entry.key, .invalidValue); continue }
                dates[key] = date; metrics.append(.init(id: metricID, canonicalKey: key, original: entry, value: nil, unit: "ISO8601")); continue
            }
            if unit == "text" {
                guard case .text(let raw) = entry.value, !raw.isEmpty, raw.count <= 1000 else { issue(entry.key, .invalidType); continue }
                metrics.append(.init(id: metricID, canonicalKey: key, original: entry, value: nil, unit: unit)); continue
            }
            guard case .number(let number) = entry.value else { issue(entry.key, .invalidType); continue }
            guard number >= 0 || key == "Balance" else { issue(entry.key, .invalidValue); continue }
            let convertsSleep = key == "Sleep" && unit == "h"
            let normalized = convertsSleep ? number * 3600 : number
            guard normalized.isFinite else { issue(entry.key, .invalidValue); continue }
            metrics.append(.init(id: metricID, canonicalKey: key, original: entry, value: normalized, unit: convertsSleep ? "s" : unit))
        }
        var interval: AutoSleepInterval?
        if let start = dates["Start"], let end = dates["Until"] {
            if end < start { issue("Start/Until", .invalidInterval) }
            else {
                interval = try .init(start: start, end: end)
                if day(end, zone: zone) != targetDate { issue("Until", .targetDateMismatch) }
                if let seconds = metrics.first(where: { $0.canonicalKey == "Sleep" && $0.unit == "s" })?.value, seconds > end.timeIntervalSince(start) { issue("Sleep", .invalidInterval) }
            }
        } else if !dates.isEmpty { issue("Start/Until", .incompleteInterval, blocking: false) }
        let record: AutoSleepRecord? = issues.contains(where: \.blocksImport) ? nil : .init(id: id, dictionary: dictionary,
            targetDate: targetDate, timeZoneID: timeZoneID, sourceRevision: sourceRevision, receivedAt: receivedAt,
            interval: interval, metrics: metrics, originalDictionary: entries, issues: issues)
        return .init(record: record, originalDictionary: entries, issues: issues)
    }
}

/// 純粋な再送照合。同じ操作IDの別内容を取り込まず、受信時刻だけが違う再送は初回を返します。
public struct AutoSleepLedger: Codable, Equatable, Sendable {
    public private(set) var records: [AutoSleepRecord]
    public init(records: [AutoSleepRecord] = []) throws {
        self.records = []; for record in records { _ = try apply(record) }
    }
    @discardableResult public mutating func apply(_ record: AutoSleepRecord) throws -> AutoSleepRecord {
        try record.validate()
        if let existing = records.first(where: { $0.id == record.id }) {
            guard existing.sameContent(as: record) else { throw AutoSleepFailure.operationIDReused }; return existing
        }
        records.append(record); return record
    }
}
