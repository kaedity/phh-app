#if DEBUG
import SwiftUI
import PHHHubCore

// オフライン表示確認専用。HubModel/認証/端末保存/Google通信を生成しません。
struct TrainingPreviewRoot: View {
    private var empty: Bool { ProcessInfo.processInfo.arguments.contains("--empty") }
    var body: some View { NavigationStack {
        if ProcessInfo.processInfo.arguments.contains("--session-edit") {
            NavigationLink("架空のSessionを開く") {
                TrainingSessionPage(snapshot:TrainingPreviewData.snapshot,session:TrainingPreviewData.snapshot.sessions[2],
                  cycles:[TrainingPreviewData.cycle],onUpdate:{ _,_,_,_ in
                    if ProcessInfo.processInfo.arguments.contains("--slow-session-save") { try? await Task.sleep(for: .seconds(8)) }
                    let failed=ProcessInfo.processInfo.arguments.contains("--failed-session-save")
                    return .init(accepted:!failed,message:failed ? "保存できません。入力を確認してください。":"端末に保存しました・同期待ち")
                  })
            }
        }
        else if ProcessInfo.processInfo.arguments.contains("--grades") { TrainingGradesPage(snapshot:empty ? .empty:TrainingPreviewData.snapshot,date:TrainingPreviewData.date) }
        else if ProcessInfo.processInfo.arguments.contains("--session") { TrainingSessionPage(snapshot:TrainingPreviewData.snapshot,session:TrainingPreviewData.snapshot.sessions[2]) }
        else { TrainingCalendarPage(snapshot:empty ? .empty:TrainingPreviewData.snapshot,status:"架空データ · オフライン表示確認",reference:empty ? nil:TrainingPreviewData.cycle,date:TrainingPreviewData.date) }
    }.tint(pine) }
}
enum TrainingPreviewData {
    static func id(_ n:Int) -> String { String(format:"00000000-0000-4000-a000-%012d",n) }
    static let date = ISO8601DateFormatter().date(from:"2026-10-02T03:00:00Z")!
    static let cycle = try! TrainingCycleReference(id:id(99),name:"架空Cycle · 9セッション",sourcePath:"synthetic-plan.md",markdown:Data((1...9).map { "## Session \($0) \(["Push-A","Pull-A","Leg-A"][($0-1)%3])" }.joined(separator:"\n").utf8))
    static let snapshot:TrainingSnapshot = {
        let dates=["2026-09-29","2026-10-01","2026-10-02","2026-10-02","2026-10-03"]
        let names=["Push","Leg","Push","Pull","Push"]
        let ss=try! (1...5).map { n in try TrainingSession(id:id(n),date:dates[n-1],name:names[n-1],lifecycle:n==5 ? .cancelled:n==4 ? .inProgress:.completed,cycleID:cycle.id,slotID:cycle.slots[[0,2,0,1,3][n-1]].id) }
        let sets=try! [
            TrainingSet(id:id(11),sessionID:id(1),exercise:"ベンチプレス",number:1,weight:50,reps:8,rpe:7),
            TrainingSet(id:id(12),sessionID:id(2),exercise:"スクワット",number:1,weight:70,reps:5),
            TrainingSet(id:id(13),sessionID:id(3),exercise:"ベンチプレス",number:1,weight:55,reps:8,rpe:8,rir:2),
            TrainingSet(id:id(14),sessionID:id(3),exercise:"ベンチプレス",number:2,weight:60,reps:5,rpe:9),
            TrainingSet(id:id(15),sessionID:id(4),exercise:"懸垂",number:1,weight:0,reps:8,basis:.bodyweight),
            TrainingSet(id:id(16),sessionID:id(4),exercise:"懸垂",number:2,weight:5,reps:5,basis:.added),
            TrainingSet(id:id(17),sessionID:id(4),exercise:"ダンベルカール",number:1,weight:10,reps:10),
            TrainingSet(id:id(18),sessionID:id(5),exercise:"ベンチプレス",number:1,weight:999,reps:1)
        ]
        let notes=try! TrainingNote.categories.enumerated().map { i,c in try TrainingNote(id:id(30+i),sessionID:id(3),category:c,speaker:i%2==0 ? "本人":"GPT",text:["架空の状態メモ。違和感は報告されていません。","架空の判断：次回も同じ重量で動きを確認。","架空の質問：休憩の長さについて。","架空の変更理由：時間の都合で補助種目を省略。"][i],exercise:i==1 ? "ベンチプレス":nil,setNumber:i==1 ? 2:nil) }
        return try! TrainingSnapshot(sessions:ss,sets:sets,notes:notes)
    }()
}
#Preview("架空のカレンダー") { TrainingPreviewRoot() }
#Preview("記録なし") { NavigationStack { TrainingCalendarPage(snapshot:.empty,status:"記録なし",date:TrainingPreviewData.date) } }
#endif
