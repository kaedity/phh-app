import Foundation

public struct RecordingDayPolicy: Codable, Equatable, Sendable {
    public let cutoffMinutes: Int
    public init(cutoffMinutes: Int = 240) throws {
        guard (0..<1440).contains(cutoffMinutes) else { throw FoodFailure.invalidValue }
        self.cutoffMinutes = cutoffMinutes
    }
    public func recordingDay(at instant: Date, explicitDay: String? = nil) throws -> String {
        if let explicitDay { try FoodRules.date(explicitDay); return explicitDay }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let clock = calendar.dateComponents([.hour, .minute], from: instant)
        let minutes = clock.hour! * 60 + clock.minute!
        let day = minutes < cutoffMinutes ? calendar.date(byAdding: .day, value: -1, to: instant)! : instant
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
