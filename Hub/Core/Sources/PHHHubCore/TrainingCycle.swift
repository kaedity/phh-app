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
