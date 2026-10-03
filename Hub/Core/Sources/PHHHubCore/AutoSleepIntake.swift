import Foundation
import CoreFoundation
import CryptoKit

public struct AutoSleepDelivery: Codable, Equatable, Identifiable, Sendable {
    public let id: String, dictionary: AutoSleepDictionary, targetDate: String, timeZoneID: String
    public let originalJSON: String, unitsJSON: String, contentHash: String
    public let receivedAt: Date, normalization: AutoSleepNormalization
}
public enum AutoSleepIntake {
    private static func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }
    public static func delivery(id: String? = nil, dictionary: AutoSleepDictionary, targetDate: String,
        timeZoneID: String, json: String, unitsJSON: String = "{}", receivedAt: Date) throws -> AutoSleepDelivery {
        guard json.utf8.count <= 100_000, unitsJSON.utf8.count <= 20_000,
          let values = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], values.count <= 200,
          let units = try JSONSerialization.jsonObject(with: Data(unitsJSON.utf8)) as? [String: String], units.count <= 200 else { throw AutoSleepFailure.invalidMetadata }
        var entries: [AutoSleepEntry] = []
        for key in values.keys.sorted() {
            let value = values[key]!, scalar: AutoSleepValue
            if value is NSNull { scalar = .missing }
            else if let n = value as? NSNumber { scalar = CFGetTypeID(n) == CFBooleanGetTypeID() ? .boolean(n.boolValue) : .number(n.doubleValue) }
            else if let text = value as? String { scalar = .text(text) }
            else { scalar = .text(String(decoding: try canonical(value), as: UTF8.self)) }
            // Sleepの時間単位だけは確認済み規則。他の独自値には明示された単位だけを付けます。
            let knownSleep = ["睡眠", "Sleep"].contains(key) && dictionary != .readiness
            entries.append(.init(key: key, value: scalar, unit: units[key] ?? (knownSleep ? "h" : nil)))
        }
        let identity: [String: Any] = ["dictionary":dictionary.rawValue,"date":targetDate,"zone":timeZoneID,"values":values,"units":units]
        let hash = SHA256.hash(data: try canonical(identity)).map { String(format: "%02x", $0) }.joined()
        let stable = String(hash.prefix(8)) + "-" + String(hash.dropFirst(8).prefix(4)) + "-" + String(hash.dropFirst(12).prefix(4)) + "-" + String(hash.dropFirst(16).prefix(4)) + "-" + String(hash.dropFirst(20).prefix(12))
        let operationID = (id ?? stable).lowercased()
        let normalization = try AutoSleepNormalizer.normalize(id: operationID, dictionary: dictionary, targetDate: targetDate, timeZoneID: timeZoneID, receivedAt: receivedAt, entries: entries)
        return AutoSleepDelivery(id: operationID, dictionary: dictionary, targetDate: targetDate, timeZoneID: timeZoneID,
            originalJSON: json, unitsJSON: unitsJSON, contentHash: hash, receivedAt: receivedAt, normalization: normalization)
    }
}
/// アプリ本体プロセスのMainActorで直列化。原辞書と診断を端末にだけ保存します。
@MainActor public final class AutoSleepInbox {
    private let url: URL
    public init(url: URL) throws {
        self.url = url; let root = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root, resource = URLResourceValues(); resource.isExcludedFromBackup = true; try directory.setResourceValues(resource)
    }
    public func deliveries() throws -> [AutoSleepDelivery] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let all = try JSONDecoder().decode([AutoSleepDelivery].self, from: Data(contentsOf: url))
        guard Set(all.map(\.id)).count == all.count else { throw AutoSleepFailure.invalidMetadata }
        for item in all {
            let verified = try AutoSleepIntake.delivery(id: item.id, dictionary: item.dictionary, targetDate: item.targetDate, timeZoneID: item.timeZoneID,
                json: item.originalJSON, unitsJSON: item.unitsJSON, receivedAt: item.receivedAt)
            guard verified == item else { throw AutoSleepFailure.invalidMetadata }
        }
        return all
    }
    @discardableResult public func receive(_ delivery: AutoSleepDelivery) throws -> AutoSleepDelivery {
        let verified = try AutoSleepIntake.delivery(id: delivery.id, dictionary: delivery.dictionary, targetDate: delivery.targetDate, timeZoneID: delivery.timeZoneID,
            json: delivery.originalJSON, unitsJSON: delivery.unitsJSON, receivedAt: delivery.receivedAt)
        guard verified == delivery else { throw AutoSleepFailure.invalidMetadata }
        var all = try deliveries()
        if let existing = all.first(where: { $0.id == delivery.id }) {
            guard existing.contentHash == delivery.contentHash else { throw AutoSleepFailure.operationIDReused }; return existing
        }
        all.append(delivery); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #if os(iOS)
        try encoder.encode(all).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try encoder.encode(all).write(to: url, options: .atomic)
        #endif
        return delivery
    }
}
