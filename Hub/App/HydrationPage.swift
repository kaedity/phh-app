import SwiftUI
import PHHHubCore
import Observation

@MainActor @Observable final class HydrationScreenModel {
    private let hub: HubStore, synthetic: Bool, onSaved: () -> Void
    private(set) var records:[HydrationRecord]=[]
    private(set) var pendingIDs:Set<String>=[]
    private(set) var enabled=false
    var message=""
    var undo:HydrationUndoChange?
    init(hub:HubStore,synthetic:Bool=false,onSaved:@escaping ()->Void) throws {self.hub=hub;self.synthetic=synthetic;self.onSaved=onSaved;try refresh()}
    func refresh() throws {records=try hub.hydrationSnapshot();pendingIDs=Set(try hub.pending().filter {$0.operation.requiresHydrationContract}.map {$0.operation.entity_id});enabled=try hub.hydrationContract==1}
    func save(_ after:HydrationRecord,before:HydrationRecord?=nil) {
        do {guard !pendingIDs.contains(after.id) else {throw HubError.invalidOperation};let op=try after.operation(synthetic:synthetic);try hub.enqueue(op);undo=HydrationUndoChange(operationID:op.id,before:before,after:after);try refresh();message="端末に保存しました・同期待ち";onSaved()}
        catch {message="水分を保存できませんでした。入力と送信待ちを確認してください。"}
    }
    func restore(){guard let undo else {return};do {try hub.undoHydrationChange(undo,synthetic:synthetic);self.undo=nil;try refresh();message="元に戻す操作を端末に保存しました";onSaved()}catch {message="元に戻せませんでした。現在の記録を確認してください。"}}
}
private enum WaterPreferences {
    static var value:HydrationPreferences {let d=UserDefaults.standard;return (try? .init(addAmountML:d.object(forKey:"water.addML") as? Double ?? 250,dailyGoalML:d.object(forKey:"water.goalML") as? Double)) ?? (try! .init())}
    static func save(_ p:HydrationPreferences){UserDefaults.standard.set(p.addAmountML,forKey:"water.addML");if let goal=p.dailyGoalML{UserDefaults.standard.set(goal,forKey:"water.goalML")}else{UserDefaults.standard.removeObject(forKey:"water.goalML")}}
}
struct HydrationCard:View {
    private var motionPolicy=MotionPolicy()
    @Bindable var model:HydrationScreenModel
    let date:String
    var showDetails=true
    @State private var preferences=WaterPreferences.value
    var body:some View {
        let summary=try? HydrationAggregation.day(date,records:model.records,preferences:preferences)
        HubMockCard {
            HStack {Label("水分",systemImage:"drop.fill").font(.headline);Spacer();if showDetails{NavigationLink("記録・設定"){HydrationPage(model:model,date:date).toolbar(.visible,for:.navigationBar)}}}
            HStack(alignment:.center){WaterCupMotion(level:summary?.progress ?? ((summary?.recordCount ?? 0)>0 ? 0.78:0),reduced:motionPolicy.reduced).frame(width:40,height:48).accessibilityHidden(true).animation(Motion.gentle(reduceMotion:motionPolicy.reduced),value:summary?.totalML);MockFigure(value:summary.map {foodNumber($0.totalML)} ?? "—",unit:"ml",size:28);Spacer();Button("＋\(foodNumber(preferences.addAmountML)) ml"){if let record=try? HydrationRecord(date:date,amountML:preferences.addAmountML){Haptics.emit(.lightPress);withAnimation(Motion.animation(reduceMotion:motionPolicy.reduced)){model.save(record)}}}.buttonStyle(.borderedProminent).tint(pine).disabled(!model.enabled).accessibilityIdentifier("water-add")}
            if let goal=summary?.goalML {ProgressView(value:summary?.progress ?? 0).tint(pine);Text("目標 \(foodNumber(goal)) ml · 残り \(foodNumber(summary?.remainingML)) ml").font(.caption).foregroundStyle(.secondary)}
            if !model.enabled {Text("同期して水分記録の接続を確認してください。").font(.caption).foregroundStyle(.secondary)}
            if !model.message.isEmpty {Text(model.message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("water-status")}
            if let undo=model.undo {HStack{Text("水分の変更を保存しました").font(.caption);Spacer();Button("元に戻す"){model.restore()}.accessibilityIdentifier("water-undo")}.task(id:undo.id){try? await Task.sleep(for:.seconds(5));if model.undo?.id==undo.id{model.undo=nil}}}
        }.onAppear {preferences=WaterPreferences.value}
    }
}
struct HydrationPage:View {
    @Bindable var model:HydrationScreenModel
    let date:String
    @State private var preferences=WaterPreferences.value
    @State private var add=""
    @State private var goal=""
    @State private var settingsMessage=""
    @State private var editing:HydrationRecord?
    @State private var removing:HydrationRecord?
    var body:some View {
        HubMockPage(title:"水分",showNavigation:true){
            HydrationCard(model:model,date:date,showDetails:false)
            HubMockCard {
                Text("追加量と目標").font(.headline)
                TextField("1回の量（ml）",text:$add).keyboardType(.decimalPad).accessibilityIdentifier("water-step-input")
                TextField("1日の目標（ml・未設定なら空欄）",text:$goal).keyboardType(.decimalPad).accessibilityIdentifier("water-goal-input")
                Button("設定を保存") {do {guard let ml=Double(add),goal.trimmingCharacters(in:.whitespaces).isEmpty || Double(goal) != nil else {throw HubError.invalidOperation};let p=try HydrationPreferences(addAmountML:ml,dailyGoalML:goal.isEmpty ? nil:Double(goal));WaterPreferences.save(p);preferences=p;settingsMessage="設定を保存しました"}catch{settingsMessage="0より大きい数値を入力してください。"}}
                if !settingsMessage.isEmpty{Text(settingsMessage).font(.caption).foregroundStyle(.secondary)}
            }
            Text("\(date)の記録").font(.headline)
            ForEach(model.records.filter {!$0.removed && $0.date==date}){r in
                HubMockCard{HStack{MockFigure(value:foodNumber(r.amountML),unit:"ml",size:24);Spacer();Text(model.pendingIDs.contains(r.id) ? "送信待ち":"同期済み").font(.caption).foregroundStyle(.secondary)};HStack{Button("変更"){editing=r};Spacer();Button("取消",role:.destructive){removing=r}}.disabled(model.pendingIDs.contains(r.id))}
            }
            if model.records.filter({!$0.removed && $0.date==date}).isEmpty{Text("水分の記録はありません").foregroundStyle(.secondary)}
        }.onAppear{preferences=WaterPreferences.value;add=String(format:"%g",preferences.addAmountML);goal=preferences.dailyGoalML.map {String(format:"%g",$0)} ?? ""}
        .sheet(item:$editing){r in NavigationStack{WaterEditPage(record:r){after in model.save(after,before:r)}}}
        .alert("この水分の記録を取り消しますか？",isPresented:Binding(get:{removing != nil},set:{if !$0{removing=nil}})){Button("戻る",role:.cancel){removing=nil};Button("取り消す",role:.destructive){if let r=removing,let after=try? r.edited(removed:true){model.save(after,before:r)};removing=nil}}message:{if let r=removing{Text("\(r.date) · \(foodNumber(r.amountML)) ml")}}
    }
}
private struct WaterEditPage:View {
    let record:HydrationRecord,save:(HydrationRecord)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var amount=""
    @State private var date=""
    @State private var message=""
    var body:some View{Form{TextField("量（ml）",text:$amount).keyboardType(.decimalPad);TextField("日付 yyyy-MM-dd",text:$date);if !message.isEmpty{Text(message)};Button("変更を保存"){do{guard let ml=Double(amount) else {throw HubError.invalidOperation};save(try record.edited(date:date,amountML:ml));dismiss()}catch{message="日付と0より大きい量を確認してください。"}}}.navigationTitle("水分の変更").toolbar{ToolbarItem(placement:.cancellationAction){Button("戻る"){dismiss()}}}.onAppear{amount=String(format:"%g",record.amountML);date=record.date}}
}

private nonisolated struct WaterCupMotion: View, Animatable {
    var level:Double
    let reduced:Bool
    var animatableData:Double {get{level}set{level=newValue}}
    var body:some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:reduced)){tick in
            Canvas {context,size in
                let rect=CGRect(x:3,y:3,width:size.width-6,height:size.height-6),cup=Path(roundedRect:rect,cornerRadius:7)
                context.stroke(cup,with:.color(pine.opacity(0.35)),lineWidth:2)
                guard level>0 else {return}
                context.clip(to:cup)
                let time=reduced ? 0:tick.date.timeIntervalSinceReferenceDate,base=rect.maxY-rect.height*min(1,max(0,level))
                var water=Path();water.move(to:CGPoint(x:rect.minX,y:rect.maxY))
                for x in stride(from:rect.minX,through:rect.maxX,by:1){water.addLine(to:CGPoint(x:x,y:base+(reduced ? 0:sin(x/8+time*3)*2)))}
                water.addLine(to:CGPoint(x:rect.maxX,y:rect.maxY));water.closeSubpath();context.fill(water,with:.color(pine.opacity(0.6)))
            }
        }
    }
}
