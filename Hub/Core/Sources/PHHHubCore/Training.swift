import Foundation

public enum TrainingKind: String, CaseIterable, Codable, Sendable { case push = "Push", pull = "Pull", leg = "Leg"
    public static func parse(_ name: String) -> TrainingKind? {
        allCases.first { kind in name == kind.rawValue || (name.hasPrefix(kind.rawValue) && Int(name.dropFirst(kind.rawValue.count)).map { $0 >= 2 } == true) }
    }
}
public enum TrainingLifecycle: String, Codable, Sendable { case planned, inProgress = "in_progress", completed, cancelled }
public enum TrainingWeightBasis: String, CaseIterable, Codable, Sendable { case standard = "通常", bodyweight = "自重", added = "加重", assisted = "補助" }
public enum TrainingExercise: String, CaseIterable, Identifiable, Sendable {
    case bench = "ベンチプレス", squat = "スクワット", deadlift = "デッドリフト", pullup = "懸垂"
    public var id: String { rawValue }
    public static func identify(_ name: String) -> Self? {
        switch name { case "ベンチプレス", "バーベルベンチプレス": .bench; case "スクワット", "バーベルスクワット": .squat; case "デッドリフト", "バーベルデッドリフト": .deadlift; case "懸垂", "チンニング", "プルアップ": .pullup; default: nil }
    }
}
public struct TrainingSession: Identifiable, Equatable, Sendable {
    public let id: String, date: String, name: String
    public let kind: TrainingKind, lifecycle: TrainingLifecycle
    public let cycleID: String?, slotID: String?, startedAt: String?, endedAt: String?
    public init(id: String, date: String, name: String, lifecycle: TrainingLifecycle = .inProgress, cycleID: String? = nil, slotID: String? = nil, startedAt: String? = nil, endedAt: String? = nil) throws {
        guard UUID(uuidString: id) != nil, Schema.validDate(date), let kind = TrainingKind.parse(name) else { throw HubError.invalidResponse }
        self.id = id; self.date = date; self.name = name; self.kind = kind; self.lifecycle = lifecycle
        self.cycleID = cycleID; self.slotID = slotID; self.startedAt = startedAt; self.endedAt = endedAt
    }
}
public struct TrainingSet: Identifiable, Equatable, Sendable {
    public let id: String, sessionID: String, exercise: String
    public let number: Int, weight: Double, reps: Int, rpe: Double?, rir: Int?
    public let basis: TrainingWeightBasis, equipment: String?, variant: String?, occurredAt: String?
    public let explicitSuccessfulMaxAttempt: Bool
    /// 本人が報告した成否。nilは未報告（成功として扱う）、falseだけを成績の計算から外す。
    public var successful: Bool? = nil
    public init(id: String, sessionID: String, exercise: String, number: Int, weight: Double, reps: Int, rpe: Double? = nil, rir: Int? = nil, basis: TrainingWeightBasis = .standard, equipment: String? = nil, variant: String? = nil, occurredAt: String? = nil, explicitSuccessfulMaxAttempt: Bool = false) throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: sessionID) != nil, !exercise.isEmpty, number > 0, weight.isFinite, weight >= 0, reps >= 0, rpe.map({ $0.isFinite && (0...10).contains($0) }) ?? true, rir.map({ $0 >= 0 }) ?? true else { throw HubError.invalidResponse }
        self.id = id; self.sessionID = sessionID; self.exercise = exercise; self.number = number; self.weight = weight; self.reps = reps; self.rpe = rpe; self.rir = rir; self.basis = basis; self.equipment = equipment; self.variant = variant; self.occurredAt = occurredAt; self.explicitSuccessfulMaxAttempt = explicitSuccessfulMaxAttempt
    }
    func with(successful: Bool?) -> TrainingSet { var copy = self; copy.successful = successful; return copy }
    public var weightLabel: String { switch basis { case .bodyweight: "自重"; case .added: "加重 +\(weight.formatted()) kg"; case .assisted: "補助 \(weight.formatted()) kg"; case .standard: "\(weight.formatted()) kg" } }
    public var measuredOneRM: Double? { explicitSuccessfulMaxAttempt && reps == 1 && basis == .standard ? weight : nil }
    /// Epley式（方式版 `epley-v1`、10/3本人決定）。通常重量の1〜10回のセットだけ。1回は重量そのもの。
    public var estimatedOneRM: Double? {
        guard basis == .standard, weight > 0, (1...10).contains(reps), successful != false else { return nil }
        return reps == 1 ? weight : (weight * (1 + Double(reps) / 30) * 10).rounded() / 10
    }
}
public struct TrainingNote: Identifiable, Equatable, Sendable {
    public static let categories = ["身体状態", "動作・効き", "備考", "メニュー変更"]
    public let id: String, sessionID: String, category: String, speaker: String, text: String
    public let exercise: String?, setNumber: Int?
    public init(id: String, sessionID: String, category: String, speaker: String, text: String, exercise: String? = nil, setNumber: Int? = nil) throws {
        guard UUID(uuidString: id) != nil, UUID(uuidString: sessionID) != nil, Self.categories.contains(category), ["本人", "GPT"].contains(speaker), !text.isEmpty else { throw HubError.invalidResponse }
        self.id = id; self.sessionID = sessionID; self.category = category; self.speaker = speaker; self.text = text; self.exercise = exercise; self.setNumber = setNumber
    }
}
public struct TrainingSnapshot: Sendable {
    public let sessions: [TrainingSession], sets: [TrainingSet], notes: [TrainingNote]
    public init(sessions: [TrainingSession], sets: [TrainingSet], notes: [TrainingNote]) throws {
        guard Set(sessions.map(\.id)).count == sessions.count, Set(sets.map(\.id)).count == sets.count, Set(notes.map(\.id)).count == notes.count else { throw HubError.invalidResponse }
        let ids = Set(sessions.map(\.id)); guard sets.allSatisfy({ ids.contains($0.sessionID) }), notes.allSatisfy({ ids.contains($0.sessionID) }) else { throw HubError.invalidResponse }
        self.sessions = sessions; self.sets = sets; self.notes = notes
    }
    public init(rows: [LocalRow]) throws {
        func text(_ row: LocalRow, _ key: String) throws -> String { guard let v = row.values[key]?.text else { throw HubError.invalidResponse }; return v }
        func integer(_ row: LocalRow, _ key: String) throws -> Int { guard let n = row.values[key]?.number, n.isFinite, n.rounded() == n, abs(n) < Double(Int.max) else { throw HubError.invalidResponse }; return Int(n) }
        let active = rows.filter(\.active)
        let sessions = try active.filter { $0.table == "TrainingSessions" }.map { r in
            let lifecycle: TrainingLifecycle
            if let value = r.values["lifecycle_state"]?.text { guard let parsed = TrainingLifecycle(rawValue: value) else { throw HubError.invalidResponse }; lifecycle = parsed } else { lifecycle = .inProgress }
            return try TrainingSession(id: r.entityID, date: text(r, "local_date"), name: text(r, "session"), lifecycle: lifecycle, cycleID: r.values["cycle_id"]?.text, slotID: r.values["plan_slot_id"]?.text, startedAt: r.values["started_at"]?.text, endedAt: r.values["ended_at"]?.text)
        }
        let sets = try active.filter { $0.table == "TrainingSets" }.map { r in
            guard let weight = r.values["weight_kg"]?.number, let basis = TrainingWeightBasis(rawValue: try text(r, "weight_basis")) else { throw HubError.invalidResponse }
            let rir = r.values["rir"]?.number == nil ? nil : try integer(r, "rir")
            return try TrainingSet(id: r.entityID, sessionID: text(r, "session_id"), exercise: text(r, "exercise"), number: integer(r, "set_no"), weight: weight, reps: integer(r, "reps"), rpe: r.values["rpe"]?.number, rir: rir, basis: basis, equipment: r.values["equipment_key"]?.text, variant: r.values["variant"]?.text, occurredAt: r.values["occurred_at"]?.text, explicitSuccessfulMaxAttempt: r.values["max_attempt"] == .bool(true) && r.values["successful"] == .bool(true))
            .with(successful: r.values["successful"] == .bool(true) ? true : r.values["successful"] == .bool(false) ? false : nil)
        }
        let notes = try active.filter { $0.table == "TrainingNotes" }.map { r in
            try TrainingNote(id: r.entityID, sessionID: text(r,"session_id"), category: text(r,"category"), speaker: text(r,"speaker"), text: text(r,"text"), exercise: r.values["exercise"]?.text, setNumber: r.values["set_no"]?.number == nil ? nil : integer(r,"set_no"))
        }
        try self.init(sessions: sessions, sets: sets, notes: notes)
    }
    public static var empty: Self { try! Self(sessions: [], sets: [], notes: []) }
    public func sets(in session: TrainingSession) -> [TrainingSet] { sets.filter { $0.sessionID == session.id }.sorted { ($0.exercise, $0.number, $0.id) < ($1.exercise, $1.number, $1.id) } }
    public func notes(in session: TrainingSession) -> [TrainingNote] { notes.filter { $0.sessionID == session.id } }
    public var performedSessions: [TrainingSession] { let ids = Set(sets.map(\.sessionID)); return sessions.filter { ids.contains($0.id) && $0.lifecycle != .cancelled } }
    public func month(_ prefix: String) -> TrainingMonth {
        let ss = performedSessions.filter { $0.date.hasPrefix(prefix + "-") }.sorted { ($0.date,$0.name,$0.id) < ($1.date,$1.name,$1.id) }
        return TrainingMonth(sessions: ss, days: Set(ss.map(\.date)).count, typeCounts: Dictionary(grouping: ss, by: \.kind).mapValues(\.count))
    }
    public func series(for exercise: TrainingExercise) -> [TrainingSeries] {
        let ss = Dictionary(uniqueKeysWithValues: performedSessions.map { ($0.id,$0) })
        let entries = sets.filter { TrainingExercise.identify($0.exercise) == exercise && ss[$0.sessionID] != nil }
        let groups = Dictionary(grouping: entries) { [$0.exercise,$0.basis.rawValue,$0.equipment ?? "機器未記録",$0.variant ?? "標準"].joined(separator:"／") }
        return groups.map { key, sets in TrainingSeries(id: key, basis: sets[0].basis, sets: sets.sorted { (ss[$0.sessionID]!.date,$0.number,$0.id) < (ss[$1.sessionID]!.date,$1.number,$1.id) }, dates: sets.reduce(into: [:]) { $0[$1.id] = ss[$1.sessionID]!.date }) }.sorted { $0.id < $1.id }
    }
}
public struct TrainingMonth: Sendable { public let sessions: [TrainingSession], days: Int, typeCounts: [TrainingKind: Int] }
public enum TrainingMetric: String, CaseIterable, Sendable { case estimatedOneRM = "推定1RM", weight = "使用重量", reps = "回数", rpe = "RPE", measuredOneRM = "実測1RM" }
public struct TrainingNextTarget: Sendable, Equatable { public let weight: Double, reps: Int, raise: Bool, reason: String
    static func short(_ iso: String) -> String { let p = iso.split(separator: "-").compactMap { Int($0) }; return p.count == 3 ? "\(p[1])/\(p[2])" : iso } }
public struct TrainingPoint: Identifiable, Sendable { public let id: String, date: String, value: Double, set: TrainingSet }
public struct TrainingSeries: Identifiable, Sendable {
    public let id: String, basis: TrainingWeightBasis, sets: [TrainingSet], dates: [String:String]
    public func within(from: String, to: String) -> Self {
        let filtered=sets.filter { dates[$0.id].map { $0>=from && $0<=to } ?? false }
        let ids=Set(filtered.map(\.id))
        return Self(id:id,basis:basis,sets:filtered,dates:dates.filter { ids.contains($0.key) })
    }
    public func points(_ metric: TrainingMetric) -> [TrainingPoint] {
        let eligible = sets.filter { !(metric != .reps && metric != .rpe && $0.successful == false) }.compactMap { set -> TrainingPoint? in
            let value: Double? = switch metric { case .weight: basis == .bodyweight ? nil : set.weight; case .reps: Double(set.reps); case .rpe: set.rpe; case .measuredOneRM: set.measuredOneRM; case .estimatedOneRM: set.estimatedOneRM }
            guard let value, let date = dates[set.id] else { return nil }; return TrainingPoint(id:set.id,date:date,value:value,set:set)
        }
        return Dictionary(grouping: eligible,by: \.date).values.compactMap { $0.max { ($0.value,$0.set.reps,$0.id) < ($1.value,$1.set.reps,$1.id) } }.sorted { ($0.date,$0.id) < ($1.date,$1.id) }
    }
    /// それまでの全期間の最高を上回った日の代表点。最初の記録は比較相手がないので自己ベストにしない。
    public func personalBestIDs(_ metric: TrainingMetric) -> Set<String> {
        // 補助つきは補助が少ないほど強いので、重量の最高を自己ベストにしない。
        guard [.estimatedOneRM, .weight, .measuredOneRM].contains(metric), basis != .assisted else { return [] }
        var best: Double?, ids = Set<String>()
        for point in points(metric) { if let b = best, point.value > b { ids.insert(point.id) }; best = max(best ?? point.value, point.value) }
        return ids
    }
    /// 前回の日の最大重量のセットだけを見る目安。全セットが同じ回数に届いていれば+2.5kg。計画mdが優先。
    public func nextTarget(increment: Double = 2.5) -> TrainingNextTarget? {
        guard basis == .standard, let last = sets.compactMap({ dates[$0.id] }).max() else { return nil }
        let day = sets.filter { dates[$0.id] == last && $0.weight > 0 }
        guard let top = day.map(\.weight).max() else { return nil }
        let topSets = day.filter { $0.weight == top }, goal = topSets.map(\.reps).max()!
        let reps = topSets.map { String($0.reps) }.joined(separator: "・"), w = top.formatted()
        if topSets.count >= 2 && topSets.allSatisfy({ $0.reps >= goal && $0.successful != false }) {
            return .init(weight: top + increment, reps: goal, raise: true, reason: "前回（\(TrainingNextTarget.short(last))）は\(w)kgの全\(topSets.count)セットで\(goal)回に届きました。")
        }
        return .init(weight: top, reps: goal, raise: false, reason: "前回（\(TrainingNextTarget.short(last))）は\(w)kgで\(reps)回。まず全セット\(goal)回を目標にします。")
    }
}

extension TrainingSnapshot {
    /// 今進めているCycleを先頭にする。名前順（"Cycle10"が"Cycle9"より前）で選ばないため（10/4レビュー）。
    /// 9枠が埋まっていないCycleのうち最近のセッションがあるもの → まだセッションがない新しいCycle → 完了したCycleの順。
    public func currentFirst(_ cycles: [TrainingCycleReference]) -> [TrainingCycleReference] {
        let last = Dictionary(grouping: performedSessions.filter { $0.cycleID != nil }, by: { $0.cycleID! }).mapValues { $0.map(\.date).max()! }
        func rank(_ c: TrainingCycleReference) -> Int { let done = c.completedSlots(in: self).count >= c.slots.count; return done ? 2 : last[c.id] != nil ? 0 : 1 }
        return cycles.sorted { a, b in
            let ra = rank(a), rb = rank(b); if ra != rb { return ra < rb }
            let la = last[a.id] ?? "", lb = last[b.id] ?? ""; if la != lb { return la > lb }
            return a.name.localizedStandardCompare(b.name) == .orderedDescending
        }
    }
}
