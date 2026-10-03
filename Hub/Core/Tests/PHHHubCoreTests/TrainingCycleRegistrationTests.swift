import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct TrainingCycleRegistrationTests {
    let base=TrainingTests()
    func setup(_ url:URL?=nil) throws -> HubStore {
        let hub=try HubStore(url:url,owner:"synthetic@example.test")
        try hub.apply(.init(schema_version:1,environment:hubEnvironment,generation:1,training_contract:1,snapshot_revision:0,changes:[],next_cursor:0,has_more:false))
        return hub
    }
    @Test func copyBlockUsesAllNineRegisteredSlotsAndDoesNotInventReportedFields() throws {
        let plan=try base.plan(),text=plan.recordingMarkdown
        #expect(plan.slots.allSatisfy {text.contains("`"+$0.id+"`")})
        #expect(text.contains("CycleID="+plan.id));#expect(text.contains("全セット→補足→セッション完了"))
        #expect(text.contains("本人のOK後"));#expect(text.contains("未報告値を作りません"))
        #expect(!text.contains("RPE=7"));#expect(!text.contains("成功=はい"))
        #expect(text.contains("20261010-2025-01"))
    }
    @Test func reimportBeforeCloudReceiptAndAfterRestartKeepsOneCycleAndOperation() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("hub.sqlite"),hub=try setup(url),plan=try base.plan()
        let first=try hub.stageTrainingCycle(plan,synthetic:false)
        let second=TrainingCycleReference(id:base.id(100),name:plan.name,sourcePath:plan.sourcePath,sha256:plan.sha256,slots:plan.slots)
        let reopened=try HubStore(url:url,owner:"synthetic@example.test"),again=try reopened.stageTrainingCycle(second,synthetic:false)
        #expect(first.queuedNew);#expect(!again.queuedNew);#expect(again.cycleID==plan.id)
        #expect(again.state == .queued);#expect(try reopened.pending().count==1)
        #expect(try reopened.pending().first?.operation.synthetic==false)
        let op=try #require(reopened.pending().first?.operation)
        try reopened.deferOperation(op.id,state:.conflict,message:"REVISION_CONFLICT",retryAt:.now)
        #expect(try reopened.stageTrainingCycle(second).state == .needsReview)
        #expect(try reopened.pending().count==1)
    }
    @Test func receivedCycleSurvivesRestartAndDeduplicatesBeforeCanonicalReadback() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("hub.sqlite"),hub=try setup(url),plan=try base.plan()
        _=try hub.stageTrainingCycle(plan)
        let op=try #require(hub.pending().first?.operation)
        let receipt=Receipt(environment:hubEnvironment,operation_id:op.id,status:"committed",entity_ids:[plan.id],revisions:[1],retryable:false)
        try hub.finish(receipt,operation:op)
        let reopened=try HubStore(url:url,owner:"synthetic@example.test")
        #expect(try reopened.pending().isEmpty)
        #expect(try reopened.acknowledgedTrainingCycles(confirmed:[])==[plan])
        #expect(try reopened.stageTrainingCycle(plan).state == .received)
        #expect(try reopened.pending().isEmpty)
        let rows=try base.futureRows().filter { ["TrainingCycles","TrainingPlanSlots"].contains($0.table) }
        let changes=rows.enumerated().map { n,r in ChangedRow(change:.init(change_number:n+1,table_name:r.table,entity_id:r.entityID,revision:1,indexed_revision:1,removed:false,local_date:nil),record:r.values) }
        try reopened.apply(.init(schema_version:1,environment:hubEnvironment,generation:1,training_contract:1,snapshot_revision:changes.count,changes:changes,next_cursor:changes.count,has_more:false))
        let confirmed=try TrainingCycleReference.read(rows:rows)
        #expect(try reopened.acknowledgedTrainingCycles(confirmed:confirmed).isEmpty)
        #expect(try reopened.stageTrainingCycle(plan).state == .confirmed)
    }
    @Test func differentFileOrChangedVersionIsNotSilentlyMatchedAndUnpreparedAPIRejects() throws {
        let plan=try base.plan()
        let changed=TrainingCycleReference(id:base.id(101),name:plan.name,sourcePath:plan.sourcePath,sha256:String(repeating:"b",count:64),slots:plan.slots)
        let other=TrainingCycleReference(id:base.id(102),name:plan.name,sourcePath:"another-plan.md",sha256:plan.sha256,slots:plan.slots)
        #expect(plan.matching(in:[changed,other])==nil)
        let hub=try HubStore(owner:"synthetic@example.test")
        #expect(throws:HubError.configuration) {try hub.stageTrainingCycle(plan)}
        #expect(try hub.pending().isEmpty)
    }
}
