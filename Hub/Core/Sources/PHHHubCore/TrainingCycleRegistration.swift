import Foundation

public extension TrainingCycleReference {
    /// 同じファイルの同じ版を選び直しても、登録済みIDを作り直しません。
    func matching(in references: [TrainingCycleReference]) -> TrainingCycleReference? {
        references.first { $0.sourcePath == sourcePath && $0.sha256 == sha256 }
    }

    /// 計画本文を含まず、選択した9枠のIDとSession終了後の受付手順だけを渡します。
    var recordingMarkdown: String {
        let schedule = slots.map { "- \($0.number). \($0.label)：`\($0.id)`" }.joined(separator: "\n")
        return """
        ### このCycleの記録
        CycleID：`\(id)`
        予定枠：
        \(schedule)

        受付シートの書き込み先と列形式を指定した記録ルールと一緒に使用してください。
        Sessionの途中は受付シートに書かず、報告の確認と助言だけを行います。
        本人がSession終了を伝えたら、種目ごとの重量×回数・報告された値・補足を一覧にして見せます。本人のOK後、全セット→補足→セッション完了の順で新しい行を書き足します。
        最後の行：
        `{受付番号}｜記録｜筋トレ｜{日付}｜{Push/Pull/Leg}｜セッション｜｜状態=完了; CycleID=\(id); 予定枠=\(id)#{番号}｜`
        開始・終了時刻、RPE、成功・失敗は本人が報告した場合だけ記録します。未報告値を作りません。
        受付番号はJSTの年付き日時と連番（例：20261010-2025-01）にし、書いた全行を読み直して照合してから「記録しました」と答えます。再送は同じ番号・同じ内容を使います。
        予定にないSessionは予定枠を付けず、途中終了は「状態=途中」にします。技術種目の名称・変種を保持します。後からの修正・補足・取消・戻すは新しい行へ書き足します。
        """
    }
}

public enum TrainingCycleRegistrationState: Equatable, Sendable { case queued, authentication, needsReview, received, confirmed }

public struct TrainingCycleRegistrationResult: Equatable, Sendable {
    public let cycleID: String
    public let queuedNew: Bool
    public let state: TrainingCycleRegistrationState
}

public extension HubStore {
    /// 同じ参照の再選択・再起動でも、別操作/別Cycleを二重に作りません。
    @discardableResult func stageTrainingCycle(_ reference: TrainingCycleReference, synthetic: Bool = true) throws -> TrainingCycleRegistrationResult {
        guard try trainingContract == 1 else { throw HubError.configuration }
        let known = try TrainingCycleReference.read(rows: ["TrainingCycles", "TrainingPlanSlots"].flatMap { try rows(table: $0) })
        if let saved = reference.matching(in: known) {
            return .init(cycleID: saved.id, queuedNew: false, state: .confirmed)
        }
        if let received=try acknowledgedTrainingCycles(confirmed:known).first(where:{$0.sourcePath==reference.sourcePath && $0.sha256==reference.sha256}) {
            return .init(cycleID:received.id,queuedNew:false,state:.received)
        }
        if let queued = try pending().first(where: {
            $0.operation.trainingCycle?.source_path == reference.sourcePath && $0.operation.trainingCycle?.source_sha256 == reference.sha256
        }) {
            let state:TrainingCycleRegistrationState = queued.state == .authentication ? .authentication : [.invalid,.conflict].contains(queued.state) ? .needsReview : .queued
            return .init(cycleID: queued.operation.entity_id, queuedNew: false, state:state)
        }
        var operation = HubOperation(cycle: reference)
        operation.synthetic = synthetic
        try enqueue(operation)
        return .init(cycleID: reference.id, queuedNew: true, state: .queued)
    }
}
