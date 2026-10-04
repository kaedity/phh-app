import Foundation
import Testing
@testable import PHHHubCore

struct TrainingTests {
    func id(_ n: Int) -> String { String(format:"00000000-0000-4000-a000-%012d",n) }
    func session(_ n: Int, date: String = "2026-10-01", name: String = "Push", state: TrainingLifecycle = .inProgress, cycle: String? = nil, slot: String? = nil) throws -> TrainingSession { try .init(id:id(n),date:date,name:name,lifecycle:state,cycleID:cycle,slotID:slot) }
    func set(_ n: Int, session: Int, exercise: String = "ベンチプレス", weight: Double = 50, reps: Int = 8, basis: TrainingWeightBasis = .standard, equipment: String? = nil, max: Bool = false) throws -> TrainingSet { try .init(id:id(n),sessionID:id(session),exercise:exercise,number:n,weight:weight,reps:reps,basis:basis,equipment:equipment,maxAttempt:max) }
    func plan() throws -> TrainingCycleReference { try .init(id:id(99),name:"架空Cycle",sourcePath:"synthetic-plan.md",markdown:Data((1...9).map { "## \($0). Session \($0) \(["Pull-A","Push-R/T","Leg-2"][($0-1)%3])" }.joined(separator:"\n").utf8)) }
    @Test func twoTypesAndRepeatedSameTypeAreSeparateSessionsNotThreeDays() throws {
        let ss = try [session(1),session(2,name:"Pull"),session(3,name:"Push2"),session(4,date:"2026-10-02",name:"Leg"),session(5,date:"2026-10-03")]
        let snapshot = try TrainingSnapshot(sessions:ss,sets:[set(11,session:1),set(12,session:2),set(13,session:3),set(14,session:4)],notes:[]), month=snapshot.month("2026-10")
        #expect(month.days == 2); #expect(month.sessions.count == 4); #expect(month.typeCounts[.push] == 2); #expect(month.typeCounts[.pull] == 1)
    }
    @Test func cancelledSessionsAndNotesOnlyDoNotProducePerformedDays() throws {
        let note = try TrainingNote(id:id(31),sessionID:id(2),category:"備考",speaker:"本人",text:"架空の補足")
        let snapshot = try TrainingSnapshot(sessions:[session(1,state:.cancelled),session(2)],sets:[set(11,session:1)],notes:[note])
        #expect(snapshot.month("2026-10").days == 0); #expect(snapshot.notes.count == 1)
    }
    @Test func pullupWeightModesAndMachinesRemainSeparate() throws {
        let snapshot = try TrainingSnapshot(sessions:[session(1,name:"Pull")],sets:[set(11,session:1,exercise:"懸垂",weight:0,basis:.bodyweight),set(12,session:1,exercise:"懸垂",weight:5,basis:.added),set(13,session:1,exercise:"懸垂",weight:20,basis:.assisted,equipment:"A"),set(14,session:1,exercise:"懸垂",weight:20,basis:.assisted,equipment:"B")],notes:[])
        let series=snapshot.series(for:.pullup); #expect(series.count == 4); #expect(series.first(where:{$0.basis == .bodyweight})!.points(.weight).isEmpty); #expect(series.first(where:{$0.basis == .bodyweight})!.points(.reps).first?.value == 8)
    }
    @Test func unreportedRPEAndSingleRepetitionDoNotBecomeMaximumAttempts() throws {
        let a=try set(11,session:1,weight:100,reps:1),b=try set(12,session:1,weight:90,reps:1,max:true)
        #expect(a.rpe == nil); #expect(a.rir == nil); #expect(a.measuredOneRM == nil); #expect(b.measuredOneRM == 90)
        let snapshot=try TrainingSnapshot(sessions:[session(1)],sets:[a,b],notes:[])
        #expect(snapshot.series(for:.bench)[0].points(.rpe).isEmpty); #expect(snapshot.series(for:.bench)[0].points(.weight)[0].id == a.id)
    }
    @Test func representativePointHasTheExactSupportingSet() throws {
        let snapshot=try TrainingSnapshot(sessions:[session(1),session(2,date:"2026-10-02")],sets:[set(11,session:1,weight:50),set(12,session:1,weight:60,reps:6),set(13,session:2,weight:55)],notes:[]), points=snapshot.series(for:.bench)[0].points(.weight)
        #expect(points.map(\.value) == [60,55]); #expect(points[0].set.reps == 6); #expect(points[0].id == id(12))
    }
    @Test func missingSessionAndDuplicateIDsRejectInsteadOfReturningAnEmptyReport() throws {
        #expect(throws:HubError.invalidResponse) { try TrainingSnapshot(sessions:[],sets:[set(11,session:1)],notes:[]) }
        #expect(throws:HubError.invalidResponse) { try TrainingSnapshot(sessions:[session(1),session(1)],sets:[],notes:[]) }
    }
    @Test func nineSlotProgressDeduplicatesSplitSessionsAndExcludesExtraOrCancelled() throws {
        let p=try plan(),ss=try [session(1,name:"Pull",state:.completed,cycle:p.id,slot:p.slots[0].id),session(2,name:"Pull",state:.completed,cycle:p.id,slot:p.slots[0].id),session(3,state:.inProgress,cycle:p.id,slot:p.slots[1].id),session(4,state:.completed,cycle:p.id),session(5,state:.cancelled,cycle:p.id,slot:p.slots[2].id)]
        let snapshot=try TrainingSnapshot(sessions:ss,sets:[],notes:[])
        #expect(p.slots.count == 9); #expect(p.completedSlots(in:snapshot) == [p.slots[0].id])
    }
    @Test func planReferenceRejectsIncompleteDuplicateSlotsAndChangedBytes() throws {
        let p=try plan(); #expect(!p.matches(Data("changed".utf8)))
        #expect(throws:HubError.invalidOperation) { try TrainingCycleReference(name:"不完全",sourcePath:"local.md",markdown:Data("## Session 1 Push-A".utf8)) }
        #expect(throws:HubError.invalidOperation) { try TrainingCycleReference(name:"重複",sourcePath:"local.md",markdown:Data((1...9).map { _ in "## Session 1 Push-A" }.joined(separator:"\n").utf8)) }
    }
    @Test func actualP2ContractCanBeReadWithoutInventingLifecycleTimesOrRPE() throws {
        let url=Bundle.module.url(forResource:"server-fixture",withExtension:"json")!,object=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        let delta=try JSONDecoder().decode(Delta.self,from:JSONSerialization.data(withJSONObject:object["latest"]!))
        let rows=delta.changes.map { LocalRow(table:$0.change.table_name,values:$0.record) }, snapshot=try TrainingSnapshot(rows:rows)
        #expect(snapshot.sets.count == 1); #expect(snapshot.sets[0].rpe == nil); #expect(snapshot.sessions[0].lifecycle == .inProgress); #expect(snapshot.sessions[0].endedAt == nil)
    }
    @Test @MainActor func trainingOperationsSurviveOutboxReloadAndEmitExplicitNull() throws {
        let cycle=try plan(),op=HubOperation(cycle:cycle);try op.validate()
        let store=try HubStore(owner:"synthetic@example.test");try store.enqueue(op)
        #expect(try store.pending().first?.operation == op)
        let update=HubOperation(sessionID:id(1),revision:1,state:.completed);try update.validate()
        let data=try JSONEncoder().encode(update),json=try JSONSerialization.jsonObject(with:data) as! [String:Any],payload=json["payload"] as! [String:Any]
        #expect(payload["cycle_id"] is NSNull);#expect(payload["plan_slot_id"] is NSNull)
        #expect(try JSONDecoder().decode(HubOperation.self,from:data) == update)
    }
    @Test func wrongSessionKindCannotCompleteAPlanSlotAndZeroRepetitionsAreReported() throws {
        let p=try plan(),snapshot=try TrainingSnapshot(sessions:[session(1,state:.completed,cycle:p.id,slot:p.slots[0].id)],sets:[],notes:[])
        #expect(p.completedSlots(in:snapshot).isEmpty)
        let failed=try set(11,session:1,reps:0);#expect(failed.reps == 0);#expect(failed.measuredOneRM == nil)
    }

    func exportedFixture(complete:Bool=true) throws -> TrainingExport {
        let url=Bundle.module.url(forResource:"server-fixture",withExtension:"json")!,object=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        let delta=try JSONDecoder().decode(Delta.self,from:JSONSerialization.data(withJSONObject:object["latest"]!))
        // 差分の複数版を最新IDへ解決済みの取得スナップショットに変換。
        var rows:[String:LocalRow]=[:];for item in delta.changes { let row=LocalRow(table:item.change.table_name,values:item.record);rows[row.id]=row }
        return TrainingExport(rows:Array(rows.values),acquiredAt:"2026-10-02T04:00:00Z",complete:complete)
    }
    @Test func boundedReportKeepsRPEMissingIDsAndPartialScopeVisible() throws {
        let export=try exportedFixture(complete:false),data=try export.report(from:"2026-10-01",to:"2026-10-01",exercise:"ダンベルカール",metric:.rpe,limit:1,includeNotes:true),json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        #expect(json["input_complete"] as? Bool == false);#expect(json["returned_count"] as? Int == 1);#expect(json["missing_metric_in_received"] as? Int == 1)
        let items=json["items"] as! [[String:Any]];#expect(items[0]["rpe"] is NSNull);#expect(items[0]["metric_value"] is NSNull);#expect(items[0]["id"] as? String != nil)
        let noMatch=try JSONSerialization.jsonObject(with:export.report(from:"2026-11-01",to:"2026-11-02")) as! [String:Any];#expect(noMatch["matching_sets_in_received"] as? Int == 0);#expect(noMatch["input_complete"] as? Bool == false)
    }
    @Test func reportRejectsIncompleteFormatUnknownMetricRangeAndMissingCycleReference() throws {
        let export=try exportedFixture();#expect(throws:HubError.invalidResponse) {try export.report(from:"bad",to:"2026-10-02")};#expect(throws:HubError.invalidResponse) {try export.report(from:"2026-10-01",to:"2026-10-02",limit:101)}
        #expect(throws:HubError.remote("CYCLE_REFERENCE_NOT_ACQUIRED")) {try export.report(from:"2026-10-01",to:"2026-10-02",cycle:id(99))}
    }

    func futureRows() throws -> [LocalRow] {
        let p=try plan()
        func row(_ table:String,_ identifier:String,_ fields:[String:Cell])->LocalRow {
            var values=Dictionary(uniqueKeysWithValues:Schema.trainingP3.tables[table]!.columns.map {($0.name,Cell.null)})
            values.merge(["id":.string(identifier),"revision":.number(1),"status":.string("active"),"created_at":.string("2026-10-02T00:00:00Z"),"updated_at":.string("2026-10-02T00:00:00Z"),"source_kind":.string("conversation"),"last_operation_id":.string(id(500))]) {_,new in new}
            values.merge(fields) {_,new in new};return LocalRow(table:table,values:values)
        }
        var rows=[row("TrainingCycles",p.id,["name":.string(p.name),"source_path":.string(p.sourcePath),"source_sha256":.string(p.sha256)])]
        rows += p.slots.map {row("TrainingPlanSlots",$0.id,["cycle_id":.string(p.id),"number":.number(Double($0.number)),"label":.string($0.label),"kind":.string($0.kind.rawValue)])}
        for n in 1...3 { rows.append(row("TrainingSessions",id(n),["local_date":.string(n==3 ? "2026-10-03":"2026-10-02"),"time_zone":.string("Asia/Tokyo"),"session":.string("Push"),"lifecycle_state":.string(n==3 ? "cancelled":"completed"),"cycle_id":n==1 ? .string(p.id):.null,"plan_slot_id":n==1 ? .string(p.slots[1].id):.null])) }
        for n in 11...14 { rows.append(row("TrainingSets",id(n),["session_id":.string(id(n==14 ? 3:n==13 ? 2:1)),"exercise":.string("ベンチプレス"),"set_no":.number(Double(n)),"weight_kg":.number(Double(n==14 ? 999:n*5)),"reps":.number(5),"rpe":n==11 ? .number(7):.null,"weight_basis":.string("通常")])) }
        rows.append(row("TrainingNotes",id(31),["session_id":.string(id(1)),"category":.string("身体状態"),"speaker":.string("本人"),"text":.string(String(repeating:"架空",count:500))]))
        return rows
    }
    @Test func reportFiltersCycleAndDatePagesWithoutMixingCancelledExtraOrMissingRPE() throws {
        let rows=try futureRows(),export=TrainingExport(rows:rows,acquiredAt:"2026-10-02T04:00:00Z",complete:true),p=try plan()
        let a=try JSONSerialization.jsonObject(with:export.report(from:"2026-10-02",to:"2026-10-02",cycle:p.id,exercise:"ベンチプレス",metric:.rpe,limit:1,includeNotes:true)) as! [String:Any]
        #expect(a["matching_sets_in_received"] as? Int == 2);#expect(a["missing_metric_in_received"] as? Int == 1);#expect(a["returned_count"] as? Int == 1);#expect(a["omitted_count"] as? Int == 1);#expect(a["next_offset"] as? Int == 1)
        let b=try JSONSerialization.jsonObject(with:export.report(from:"2026-10-02",to:"2026-10-02",cycle:p.id,offset:1,limit:1)) as! [String:Any]
        let ai=(a["items"] as! [[String:Any]])[0],bi=(b["items"] as! [[String:Any]])[0];#expect(ai["id"] as? String != bi["id"] as? String);#expect(b["next_offset"] is NSNull)
        let notes=a["notes"] as! [[String:Any]];#expect(notes[0]["text_omitted"] as? Bool == true);#expect((notes[0]["text"] as? String)?.count == 800)
        let references=try TrainingCycleReference.read(rows:rows),snapshot=try TrainingSnapshot(rows:rows);#expect(references.first?.completedSlots(in:snapshot).count == 1)
    }
    @Test func nullOnlyUpgradePreservesRecordButSameRevisionChangedValueRejects() throws {
        let row=try futureRows().first {$0.table=="TrainingSessions"}!,keys=Set(Schema.bundled.tables[row.table]!.columns.map(\.name))
        let old=row.values.filter {keys.contains($0.key)},nulls=old.merging(["lifecycle_state":Cell.null,"plan_slot_id":Cell.null]) {_,new in new}
        #expect(Schema.sameRecordDuringP3Upgrade(table:row.table,old:old,new:nulls));#expect(!Schema.sameRecordDuringP3Upgrade(table:row.table,old:old,new:row.values))
    }

    @Test func duplicateExportRowsRejectRatherThanCrashingOrChoosingOneRevision() throws {
        var rows=try futureRows();rows.append(rows.first {$0.table=="TrainingSets"}!)
        let export=TrainingExport(rows:rows,acquiredAt:"2026-10-02T04:00:00Z",complete:true)
        #expect(throws:HubError.invalidResponse) {try export.report(from:"2026-10-01",to:"2026-10-03")}
    }

    @Test func selectedPeriodKeepsOnlyInclusiveDatesAndTheirSupportingSets() throws {
        let snapshot=try TrainingSnapshot(sessions:[session(1,date:"2026-09-01"),session(2,date:"2026-10-01"),session(3,date:"2026-10-02"),session(4,date:"2026-10-03")],sets:[set(11,session:1,weight:50),set(12,session:2,weight:60),set(13,session:3,weight:55),set(14,session:4,weight:99)],notes:[])
        let series=snapshot.series(for:.bench)[0].within(from:"2026-10-01",to:"2026-10-02")
        #expect(series.points(.weight).map(\.value) == [60,55]);#expect(series.sets.map(\.id) == [id(12),id(13)])
        #expect(series.dates.count == 2);#expect(series.points(.rpe).isEmpty)
        #expect(series.within(from:"2026-11-01",to:"2026-11-02").sets.isEmpty)
    }

}

struct TrainingEstimateTests {
    let base = TrainingTests()
    @Test func epleyAppliesOnlyToStandardSetsOfOneToTenReps() throws {
        #expect(try base.set(1,session:1,weight:60,reps:8).estimatedOneRM == 76)
        #expect(try base.set(2,session:1,weight:100,reps:1).estimatedOneRM == 100)
        #expect(try base.set(3,session:1,weight:60,reps:11).estimatedOneRM == nil)
        #expect(try base.set(4,session:1,exercise:"懸垂",weight:10,reps:5,basis:.added).estimatedOneRM == nil)
        #expect(try base.set(5,session:1,exercise:"懸垂",weight:0,reps:8,basis:.bodyweight).estimatedOneRM == nil)
    }
    @Test func personalBestMarksOnlyDaysAboveEveryEarlierDay() throws {
        let ss = try [base.session(1,date:"2026-10-01"),base.session(2,date:"2026-10-03"),base.session(3,date:"2026-10-05"),base.session(4,date:"2026-10-07")]
        let sets = try [base.set(11,session:1,weight:60,reps:8),base.set(12,session:2,weight:60,reps:6),base.set(13,session:3,weight:62.5,reps:8),base.set(14,session:4,weight:62.5,reps:8)]
        let series = try TrainingSnapshot(sessions:ss,sets:sets,notes:[]).series(for:.bench)[0]
        #expect(series.personalBestIDs(.estimatedOneRM) == [base.id(13)])
        #expect(series.personalBestIDs(.rpe).isEmpty)
    }
    @Test func variationsStayInTheirOwnSeriesSoTheyNeverBeatTheMainLift() throws {
        let ss = try [base.session(1,date:"2026-10-01"),base.session(2,date:"2026-10-03")]
        let pause = try TrainingSet(id:base.id(12),sessionID:base.id(2),exercise:"ベンチプレス",number:1,weight:70,reps:5,variant:"ポーズ")
        let series = try TrainingSnapshot(sessions:ss,sets:[base.set(11,session:1,weight:60,reps:8),pause],notes:[]).series(for:.bench)
        #expect(series.count == 2)
        #expect(series.allSatisfy { $0.personalBestIDs(.estimatedOneRM).isEmpty })
    }
    @Test func nextTargetRaisesOnlyWhenEveryTopSetReachedTheReps() throws {
        let ss = try [base.session(1,date:"2026-10-01"),base.session(2,date:"2026-10-03")]
        let reached = try TrainingSnapshot(sessions:ss,sets:[base.set(11,session:1,weight:55,reps:8),base.set(12,session:2,weight:60,reps:8),base.set(13,session:2,weight:60,reps:8)],notes:[]).series(for:.bench)[0].nextTarget()
        #expect(reached == TrainingNextTarget(weight:62.5,reps:8,raise:true,reason:"前回（10/3）は60kgの全2セットで8回に届きました。"))
        let short = try TrainingSnapshot(sessions:ss,sets:[base.set(12,session:2,weight:60,reps:8),base.set(13,session:2,weight:60,reps:6)],notes:[]).series(for:.bench)[0].nextTarget()
        #expect(short?.raise == false); #expect(short?.weight == 60); #expect(short?.reps == 8)
        let bodyweight = try TrainingSnapshot(sessions:ss,sets:[base.set(14,session:2,exercise:"懸垂",weight:0,reps:8,basis:.bodyweight)],notes:[]).series(for:.pullup)[0].nextTarget()
        #expect(bodyweight == nil)
    }
}

struct TrainingReviewFixTests {
    let base = TrainingTests()
    /// 成功・失敗の区別はない（10/4本人決定）。疲労で回数が落ちたセットもそのまま数え、目安は回数で決める。
    @Test func everyRecordedSetCountsAndFewerRepsKeepTheTarget() throws {
        let ss = try [base.session(1,date:"2026-10-01"),base.session(2,date:"2026-10-03")]
        let first = try base.set(11,session:1,weight:60,reps:8), heavy = try base.set(12,session:2,weight:100,reps:3)
        let series = try TrainingSnapshot(sessions:ss,sets:[first,heavy],notes:[]).series(for:.bench)[0]
        #expect(series.points(.estimatedOneRM).map(\.id) == [first.id, heavy.id]); #expect(series.personalBestIDs(.estimatedOneRM) == [heavy.id])
        let target = try TrainingSnapshot(sessions:ss,sets:[try base.set(13,session:2,weight:60,reps:8),try base.set(14,session:2,weight:60,reps:6)],notes:[]).series(for:.bench)[0].nextTarget()
        #expect(target?.raise == false); #expect(target?.reps == 8)
    }
    @Test func assistedPullupsNeverBecomePersonalBests() throws {
        let ss = try [base.session(1,date:"2026-10-01",name:"Pull"),base.session(2,date:"2026-10-03",name:"Pull")]
        let series = try TrainingSnapshot(sessions:ss,sets:[try base.set(11,session:1,exercise:"懸垂",weight:20,reps:8,basis:.assisted),try base.set(12,session:2,exercise:"懸垂",weight:30,reps:8,basis:.assisted)],notes:[]).series(for:.pullup)[0]
        #expect(series.personalBestIDs(.weight).isEmpty)
    }
    @Test func currentCycleIsTheUnfinishedOneNotTheFirstByName() throws {
        func plan(_ n: Int, _ name: String) throws -> TrainingCycleReference { try .init(id:base.id(90+n),name:name,sourcePath:"p\(n).md",markdown:Data((1...9).map { "## \($0). Session \($0) \(["Pull-A","Push-R/T","Leg-2"][($0-1)%3])" }.joined(separator:"\n").utf8)) }
        let old = try plan(1,"Cycle9"), next = try plan(2,"Cycle10")
        let done = try (0..<9).map { i in try base.session(10+i,date:String(format:"2026-09-%02d",10+i),name:["Pull","Push","Leg"][i%3],state:.completed,cycle:old.id,slot:old.slots[i].id) }
        let sets = try done.enumerated().map { i, s in try base.set(100+i,session:10+i) }
        let snapshot = try TrainingSnapshot(sessions:done,sets:sets,notes:[])
        #expect(snapshot.currentFirst([old,next]).first?.id == next.id)
        let started = try base.session(30,date:"2026-10-10",name:"Pull",state:.completed,cycle:next.id,slot:next.slots[0].id)
        let later = try TrainingSnapshot(sessions:done+[started],sets:sets+[try base.set(130,session:30)],notes:[])
        #expect(later.currentFirst([old,next]).map(\.id) == [next.id, old.id])
    }
}

struct TrainingElapsedTests {
    let base = TrainingTests()
    @Test func elapsedUsesEndStartOrDateAndSwitchesToDays() throws {
        let now = TrainingElapsed.instant("2026-10-04T12:00:00+09:00")!
        let ss = try [base.session(1,date:"2026-10-03",name:"Push",state:.completed).withTimes(start:nil,end:"2026-10-03T20:00:00.000+09:00"),
                      base.session(2,date:"2026-10-01",name:"Pull",state:.completed).withTimes(start:"2026-10-01T19:00:00+09:00",end:nil),
                      base.session(3,date:"2026-10-02",name:"Leg",state:.completed)]
        let snapshot = try TrainingSnapshot(sessions:ss,sets:[try base.set(11,session:1),try base.set(12,session:2),try base.set(13,session:3)],notes:[])
        #expect(TrainingElapsed.summary(snapshot,today:"2026-10-04",now:now) == "Push 16時間 · Pull 開始から2日 · Leg 10/2（2日前）")
    }
}
extension TrainingSession {
    func withTimes(start: String?, end: String?) throws -> TrainingSession { try TrainingSession(id:id,date:date,name:name,lifecycle:lifecycle,cycleID:cycleID,slotID:slotID,startedAt:start,endedAt:end) }
}
