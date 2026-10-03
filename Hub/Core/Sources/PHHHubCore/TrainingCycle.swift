import Foundation
import CryptoKit

public struct TrainingPlanSlot: Identifiable, Codable, Equatable, Sendable {
    public let id: String, number: Int, label: String, kind: TrainingKind
}
public struct TrainingCycleReference: Identifiable, Codable, Equatable, Sendable {
    public let id: String, name: String, sourcePath: String, sha256: String
    public let slots: [TrainingPlanSlot]
    public init(id: String = UUID().uuidString.lowercased(), name: String, sourcePath: String, markdown: Data) throws {
        guard UUID(uuidString: id) != nil, !name.isEmpty, markdown.count <= 1_000_000, let text = String(data: markdown, encoding: .utf8) else { throw HubError.invalidOperation }
        let regex = try NSRegularExpression(pattern: #"(?m)^##\s+(?:\d+\.\s*)?Session\s+(\d+)\s+((Push|Pull|Leg)[^\r\n]*)"#)
        let ns = text as NSString, matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let parsed = matches.map { m -> TrainingPlanSlot in
            let n = Int(ns.substring(with:m.range(at:1))) ?? 0, label = ns.substring(with:m.range(at:2)).trimmingCharacters(in:.whitespaces), kind = TrainingKind(rawValue: ns.substring(with:m.range(at:3)))!
            return TrainingPlanSlot(id: id+"#"+String(n),number:n,label:label,kind:kind)
        }.sorted { $0.number < $1.number }
        guard parsed.map(\.number) == Array(1...9) else { throw HubError.invalidOperation }
        self.id=id; self.name=name; self.sourcePath=sourcePath; self.sha256=Self.hash(markdown); self.slots=parsed
    }
    init(id:String,name:String,sourcePath:String,sha256:String,slots:[TrainingPlanSlot]) { self.id=id;self.name=name;self.sourcePath=sourcePath;self.sha256=sha256;self.slots=slots }
    public static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    public func matches(_ markdown: Data) -> Bool { Self.hash(markdown) == sha256 }
    public func completedSlots(in snapshot: TrainingSnapshot) -> Set<String> {
        let allowed = Dictionary(uniqueKeysWithValues:slots.map { ($0.id,$0.kind) })
        return Set(snapshot.sessions.filter { session in session.cycleID == id && session.lifecycle == .completed && session.slotID.map { allowed[$0] == session.kind } == true }.compactMap(\.slotID))
    }
}
public extension TrainingSnapshot {
    func lastSession(of kind: TrainingKind, onOrBefore date: String) -> TrainingSession? {
        performedSessions.filter { $0.kind == kind && $0.date <= date }.sorted { ($0.date,$0.endedAt ?? $0.startedAt ?? "",$0.id) < ($1.date,$1.endedAt ?? $1.startedAt ?? "",$1.id) }.last
    }
}

// ホームの「前回からの経過」（DESIGN 7章）。終了時刻→「Push 26時間」、開始時刻のみ→「Pull 開始から26時間」、
// 時刻なし→「Leg 10/1（2日前）」、48時間以上は日数。小数秒つきの時刻も読む。
public enum TrainingElapsed {
    static func instant(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: text)
    }
    private static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Tokyo")!; return c }
    static func span(_ hours: Int) -> String { hours >= 48 ? "\(hours / 24)日" : "\(hours)時間" }
    public static func text(for kind: TrainingKind, in snapshot: TrainingSnapshot, today: String, now: Date) -> String {
        guard let session = snapshot.lastSession(of: kind, onOrBefore: today) else { return "\(kind.rawValue) —" }
        if let end = session.endedAt.flatMap(instant) { return "\(kind.rawValue) \(span(max(0, Int(now.timeIntervalSince(end) / 3600))))" }
        if let start = session.startedAt.flatMap(instant) { return "\(kind.rawValue) 開始から\(span(max(0, Int(now.timeIntervalSince(start) / 3600))))" }
        let parts = session.date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return "\(kind.rawValue) \(session.date)" }
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        return "\(kind.rawValue) \(parts[1])/\(parts[2])（\(days == 0 ? "今日" : days == 1 ? "昨日" : "\(days)日前")）"
    }
    public static func summary(_ snapshot: TrainingSnapshot, today: String, now: Date) -> String {
        TrainingKind.allCases.map { text(for: $0, in: snapshot, today: today, now: now) }.joined(separator: " · ")
    }
}
