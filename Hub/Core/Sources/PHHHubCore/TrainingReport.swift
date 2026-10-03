import Foundation
public struct TrainingExport: Codable, Sendable {
    public struct Row: Codable, Sendable { public let table:String, values:[String:Cell]; public init(_ r:LocalRow){table=r.table;values=r.values} }
    public let format:String, environment:String, source:String, acquired_at:String
    public let synthetic:Bool, complete:Bool
    public let rows:[Row]
    public init(rows:[LocalRow],acquiredAt:String,complete:Bool,source:String="committed_canonical_snapshot") { format="phh-training-snapshot-v1";environment=hubEnvironment;self.source=source;acquired_at=acquiredAt;synthetic=true;self.complete=complete;self.rows=rows.map(Row.init) }
    public func report(from:String,to:String,cycle:String?=nil,exercise:String?=nil,metric:TrainingMetric = .weight,offset:Int=0,limit:Int=20,includeNotes:Bool=false) throws -> Data {
        let timestamp=ISO8601DateFormatter();timestamp.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let validAcquiredAt=timestamp.date(from:acquired_at) != nil || ISO8601DateFormatter().date(from:acquired_at) != nil
        guard format=="phh-training-snapshot-v1",environment==hubEnvironment,synthetic,source=="committed_canonical_snapshot",validAcquiredAt,Schema.validDate(from),Schema.validDate(to),from<=to,offset>=0,(1...100).contains(limit),cycle.map({UUID(uuidString:$0) != nil}) ?? true else { throw HubError.invalidResponse }
        let local=rows.map { LocalRow(table:$0.table,values:$0.values) }
        guard Set(local.map(\.id)).count == local.count else { throw HubError.invalidResponse }
        for row in local { try Schema.validate(row) }
        let snapshot=try TrainingSnapshot(rows:local)
        if let cycle,complete { guard try TrainingCycleReference.read(rows:local).contains(where:{$0.id==cycle}) else { throw HubError.remote("CYCLE_REFERENCE_NOT_ACQUIRED") } }
        let sessions=snapshot.performedSessions.filter { $0.date>=from && $0.date<=to && (cycle==nil || $0.cycleID==cycle) }
        let eligible=Set(sessions.map(\.id)),dates=Dictionary(uniqueKeysWithValues:sessions.map {($0.id,$0.date)})
        let sets=snapshot.sets.filter { eligible.contains($0.sessionID) && (exercise==nil || $0.exercise==exercise || TrainingExercise.identify(exercise!) == TrainingExercise.identify($0.exercise) && TrainingExercise.identify(exercise!) != nil) }.sorted { (dates[$0.sessionID]!,$0.sessionID,$0.exercise,$0.number,$0.id)<(dates[$1.sessionID]!,$1.sessionID,$1.exercise,$1.number,$1.id) }
        let revisions=Dictionary(uniqueKeysWithValues:local.filter {$0.table=="TrainingSets"}.map {($0.entityID,$0.revision)})
        func value(_ set:TrainingSet)->Double? { switch metric { case .weight:set.basis == .bodyweight ? nil:set.weight;case .reps:Double(set.reps);case .rpe:set.rpe;case .measuredOneRM:set.measuredOneRM;case .estimatedOneRM:set.estimatedOneRM } }
        func brief(_ s:String)->String { String(s.prefix(200)) }
        let page=Array(sets.dropFirst(offset).prefix(limit)),next=offset+page.count
        let items:[[String:Any]]=page.map { set in
            ["id":set.id,"revision":revisions[set.id]!,"session_id":set.sessionID,"date":dates[set.sessionID]!,"exercise":brief(set.exercise),"exercise_characters":set.exercise.count,"exercise_omitted":set.exercise.count>200,"set_no":set.number,"weight_basis":set.basis.rawValue,"weight_kg":set.weight,"reps":set.reps,"rpe":set.rpe as Any? ?? NSNull(),"rir":set.rir as Any? ?? NSNull(),"equipment":set.equipment.map(brief) as Any? ?? NSNull(),"variant":set.variant.map(brief) as Any? ?? NSNull(),"metric_value":value(set) as Any? ?? NSNull()]
        }
        let points=Dictionary(grouping:sets,by:{ [$0.exercise,$0.basis.rawValue,$0.equipment ?? "機器未記録",$0.variant ?? "標準"].joined(separator:"/") }).map { key,ss -> [String:Any] in
            let series=TrainingSeries(id:key,basis:ss[0].basis,sets:ss,dates:ss.reduce(into:[:]){$0[$1.id]=dates[$1.sessionID]!})
            let points = series.points(metric)
            return ["series":brief(key),"series_characters":key.count,"points":points.prefix(limit).map {["date":$0.date,"value":$0.value,"source_set_id":$0.id] as [String:Any]},"point_count":points.count,"points_omitted":max(0,points.count-limit)]
        }.sorted { ($0["series"] as! String)<($1["series"] as! String) }
        let notes=snapshot.notes.filter { eligible.contains($0.sessionID) && (exercise==nil || $0.exercise==nil || $0.exercise==exercise) },notesPage=includeNotes ? Array(notes.sorted {$0.id<$1.id}.prefix(limit)):[]
        let result:[String:Any] = ["format":"phh-training-report-v1","source":source,"acquired_at":acquired_at,"input_complete":complete,"scope":complete ? "取得済みの確定スナップショット全体":"部分取得。対象なし・漏れなしとは判定できません。","from":from,"to":to,"cycle_id":cycle as Any? ?? NSNull(),"exercise":exercise.map(brief) as Any? ?? NSNull(),"metric":metric.rawValue,"total_received_rows":rows.count,"matching_sets_in_received":sets.count,"missing_metric_in_received":sets.filter {value($0)==nil}.count,"performed_days_in_received":Set(sessions.map(\.date)).count,"sessions_in_received":sessions.count,"offset":offset,"returned_count":page.count,"omitted_count":sets.count-page.count,"next_offset":next<sets.count ? next as Any:NSNull(),"items":items,"series":Array(points.prefix(limit)),"series_count":points.count,"series_omitted":max(0,points.count-limit),"notes_matching":notes.count,"notes_returned":notesPage.count,"notes_omitted":notes.count-notesPage.count,"notes":notesPage.map {["id":$0.id,"session_id":$0.sessionID,"category":$0.category,"speaker":$0.speaker,"text":String($0.text.prefix(800)),"text_characters":$0.text.count,"text_omitted":$0.text.count>800] as [String:Any]}]
        let data=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted])
        guard data.count<=24_000 else { throw HubError.remote("REPORT_TOO_LARGE_USE_SMALLER_LIMIT") };return data
    }
}
