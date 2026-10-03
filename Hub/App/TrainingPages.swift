import SwiftUI
import Charts
import UniformTypeIdentifiers
import PHHHubCore

extension TrainingKind {
    var color: Color { switch self { case .push: .red; case .pull: .blue; case .leg: Color(red:0.48,green:0.63,blue:0.12) } }
}

// MARK: モック（v3）に合わせる共通の小部品（DESIGN 2.6）
private let mockTokyo = TimeZone(identifier: "Asia/Tokyo")!
/// "2026-10-03" → "10月3日（金）"。読めなければ元の文字列を返す。
func mockDay(_ iso: String) -> String {
    let i = DateFormatter(); i.locale = Locale(identifier: "en_US_POSIX"); i.timeZone = mockTokyo; i.dateFormat = "yyyy-MM-dd"
    guard let d = i.date(from: String(iso.prefix(10))) else { return iso }
    return mockDay(d)
}
func mockDay(_ date: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = mockTokyo; f.dateFormat = "M月d日（E）"; return f.string(from: date) }
func mockDayTime(_ date: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = mockTokyo; f.dateFormat = "M月d日（E）H:mm"; return f.string(from: date) }
/// "2026-10-03" → "10/3"
func mockShort(_ iso: String) -> String { let parts = iso.prefix(10).split(separator: "-"); return parts.count == 3 ? "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)" : iso }
/// ISO 8601の時刻 → "19:05"。なければnil。
func mockClock(_ iso: String?) -> String? {
    guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return nil }
    let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = mockTokyo; f.dateFormat = "H:mm"; return f.string(from: d)
}
// Preserve the mock's nutrient hues while keeping text legible on dark cards.
// UIColor resolves against the current system appearance, including live changes.
let pfcProtein = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.50, green: 0.78, blue: 0.64, alpha: 1)
        : UIColor(red: 0.14, green: 0.34, blue: 0.26, alpha: 1)
})
let pfcFat = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.90, green: 0.70, blue: 0.48, alpha: 1)
        : UIColor(red: 0.62, green: 0.38, blue: 0.16, alpha: 1)
})
let pfcCarb = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.55, green: 0.75, blue: 0.98, alpha: 1)
        : UIColor(red: 0.18, green: 0.42, blue: 0.72, alpha: 1)
})
/// 大きい数字と小さい単位（モックの「1,280 kcal」）。
struct MockFigure: View {
    let value: String, unit: String
    var size: CGFloat = 40
    var color: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: size, weight: .semibold, design: .rounded)).foregroundStyle(color).minimumScaleFactor(0.6).lineLimit(1)
            Text(unit).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(color == .primary ? .secondary : color)
        }
    }
}
/// 1枚のカードの中で区切り線を入れて並べる行（モックの一覧）。
struct MockRows<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
struct MockRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var dot: Color? = nil
    var chevron = true
    var last = false
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let dot { Circle().fill(dot).frame(width: 12, height: 12) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                trailing
                if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 16).padding(.vertical, 13).contentShape(Rectangle())
            if !last { Divider().padding(.leading, dot == nil ? 16 : 38) }
        }
    }
}
extension MockRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, dot: Color? = nil, chevron: Bool = true, last: Bool = false) {
        self.init(title: title, subtitle: subtitle, dot: dot, chevron: chevron, last: last) { EmptyView() }
    }
}

private enum TrainingDates {
    static var calendar: Calendar { var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(identifier:"Asia/Tokyo")!; c.firstWeekday=2; return c }
    static func string(_ date: Date, format: String = "yyyy-MM-dd") -> String { let f=DateFormatter();f.calendar=calendar;f.locale=Locale(identifier:"ja_JP");f.timeZone=calendar.timeZone;f.dateFormat=format;return f.string(from:date) }
    static func date(_ text: String) -> Date { let f=DateFormatter();f.calendar=calendar;f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=calendar.timeZone;f.dateFormat="yyyy-MM-dd";return f.date(from:text)! }
}

struct TrainingCalendarPage: View {
    let snapshot: TrainingSnapshot
    let status: String
    let cycles:[TrainingCycleReference]
    let saveReference:((TrainingCycleReference) async -> String)?
    let updateSession:((TrainingSession,TrainingLifecycle,TrainingCycleReference?,TrainingPlanSlot?) async -> String)?
    @State var reference: TrainingCycleReference?
    @State private var month: Date
    @State private var selected: String
    @State private var importing=false
    @State private var importMessage: String?
    init(snapshot:TrainingSnapshot,status:String,reference:TrainingCycleReference?=nil,date:Date=Date(),cycles:[TrainingCycleReference]=[],saveReference:((TrainingCycleReference) async -> String)?=nil,updateSession:((TrainingSession,TrainingLifecycle,TrainingCycleReference?,TrainingPlanSlot?) async -> String)?=nil) {
        self.snapshot=snapshot;self.status=status;self.cycles=cycles;self.saveReference=saveReference;self.updateSession=updateSession;_reference=State(initialValue:reference)
        _month=State(initialValue:TrainingDates.calendar.date(from:TrainingDates.calendar.dateComponents([.year,.month],from:date))!);_selected=State(initialValue:TrainingDates.string(date))
    }
    private var selectedSessions: [TrainingSession] { snapshot.sessions.filter { $0.date==selected }.sorted { ($0.name,$0.id)<($1.name,$1.id) } }
    var body: some View {
        let report = snapshot.month(TrainingDates.string(month,format:"yyyy-MM"))
        let selectedSessions = self.selectedSessions
        Page(title:"トレーニング") {
            if status.contains("失敗") || status.contains("できません") { Text(status).font(.caption).foregroundStyle(.secondary) }
            monthHeader
            Card { calendarGrid(report).dynamicTypeSize(...DynamicTypeSize.xxxLarge); legend }
            Card {
                AccessibleRow { Text("今月").foregroundStyle(.secondary);Text("\(report.days)日").font(.title2.bold());Text("· \(report.sessions.count)セッション").font(.subheadline) }.accessibilityIdentifier("training-month-count")
                HStack(spacing:14) { ForEach(TrainingKind.allCases,id:\.self) { kind in HStack(spacing:5) { Circle().fill(kind.color).frame(width:8,height:8);Text("\(kind.rawValue) \(report.typeCounts[kind] ?? 0)回").font(.caption) } } }
            }
            Text("\(mockDay(selected))のトレーニング").font(.headline)
            if selectedSessions.isEmpty { Card { Text("この日の記録はありません").foregroundStyle(.secondary) } }
            else {
                MockRows { ForEach(Array(selectedSessions.enumerated()), id:\.element.id) { index, session in
                    NavigationLink { TrainingSessionPage(snapshot:snapshot,session:session,cycles:cycles,onUpdate:updateSession) } label: {
                        MockRow(title: session.name, subtitle: sessionSubtitle(session), dot: session.kind.color, last: index == selectedSessions.count-1) { if let time = mockClock(session.startedAt) { Text(time).font(.subheadline).foregroundStyle(.secondary) } }
                    }.buttonStyle(.plain).accessibilityIdentifier("training-session-" + session.id)
                } }
            }
            cycleCard
            Card { NavigationLink { TrainingGradesPage(snapshot:snapshot,date:TrainingDates.date(selected)) } label: { Label("種目の成績を見る",systemImage:"chart.xyaxis.line").font(.headline).frame(maxWidth:.infinity,alignment:.leading) } }
            Card {
                Text("前回のトレーニング").font(.headline)
                ForEach(TrainingKind.allCases,id:\.self) { kind in
                    HStack { Text(kind.rawValue).foregroundStyle(kind.color);Spacer();if let last=snapshot.lastSession(of:kind,onOrBefore:selected) { Text(mockDay(last.date)).font(.subheadline) } else { Text("記録なし").foregroundStyle(.secondary) } }
                }
                Text("時刻未記録の場合は、日付だけを表示します。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[UTType(filenameExtension:"md") ?? .plainText,.plainText]) { result in
            do { let url=try result.get();let scoped=url.startAccessingSecurityScopedResource();defer { if scoped { url.stopAccessingSecurityScopedResource() } };let bytes=try Data(contentsOf:url)
                reference=try TrainingCycleReference(name:url.deletingPathExtension().lastPathComponent,sourcePath:url.lastPathComponent,markdown:bytes);importMessage="計画の9枠を読み取りました。実績は変更していません。"
            } catch { importMessage="計画を読み取れませんでした。Session 1〜9の見出しがあるmdを選んでください。前の参照を保持しています。" }
        }
    }
    private func sessionSubtitle(_ session: TrainingSession) -> String {
        let n = snapshot.sets(in:session).count
        switch session.lifecycle { case .cancelled: return "取消"; case .completed: return "完了 · \(n)セット"; default: return n == 0 ? "補足・予定のみ" : "途中 · \(n)セット" }
    }
    private var monthHeader: some View {
        HStack { Button { moveMonth(-1) } label: { Image(systemName:"chevron.left").frame(width:44,height:44) }.accessibilityLabel("前の月")
            Spacer();Text(TrainingDates.string(month,format:"yyyy年M月")).font(.title3.bold());Spacer()
            Button { moveMonth(1) } label: { Image(systemName:"chevron.right").frame(width:44,height:44) }.accessibilityLabel("次の月") }
    }
    private func moveMonth(_ amount:Int) { month=TrainingDates.calendar.date(byAdding:.month,value:amount,to:month)!;selected=TrainingDates.string(month) }
    private func calendarGrid(_ report: TrainingMonth) -> some View {
        let calendar=TrainingDates.calendar,count=calendar.range(of:.day,in:.month,for:month)!.count,offset=(calendar.component(.weekday,from:month)+5)%7
        let kindsByDate = Dictionary(grouping: report.sessions, by: \.date).mapValues { Set($0.map(\.kind)) }
        return LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:3),count:7),spacing:8) {
            ForEach(["月","火","水","木","金","土","日"],id:\.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            ForEach(0..<(offset+count),id:\.self) { index in
                if index<offset { Color.clear.frame(height:44) } else {
                    let day=calendar.date(byAdding:.day,value:index-offset,to:month)!,date=TrainingDates.string(day),kinds=TrainingKind.allCases.filter { kindsByDate[date]?.contains($0) == true }
                    Button { selected=date } label: {
                        VStack(spacing:4) { Text(String(index-offset+1)).font(.subheadline);HStack(spacing:3) { ForEach(kinds,id:\.self) { Circle().fill($0.color).frame(width:5,height:5) } }.frame(height:6) }.frame(maxWidth:.infinity,minHeight:44).background(selected==date ? pine.opacity(0.12):Color.clear,in:RoundedRectangle(cornerRadius:10))
                    }.buttonStyle(.plain).accessibilityLabel(date+" "+kinds.map(\.rawValue).joined(separator:"・")).accessibilityIdentifier("training-day-"+date)
                }
            }
        }
    }
    private var legend: some View { HStack(spacing:18) { ForEach(TrainingKind.allCases,id:\.self) { kind in HStack(spacing:5) { Circle().fill(kind.color).frame(width:8,height:8);Text(kind.rawValue).font(.caption) } } }.padding(.top,5) }
    private var cycleCard: some View {
        Card {
            if let reference {
                let completed=reference.completedSlots(in:snapshot)
                if cycles.count>1 { Picker("表示するCycle",selection:Binding(get:{reference.id},set:{id in self.reference=cycles.first {$0.id==id}})) { ForEach(cycles) { Text($0.name).tag($0.id) };if !cycles.contains(where:{$0.id==reference.id}) { Text(reference.name).tag(reference.id) } } }
                Text(reference.name).font(.headline);Label("Cycle \(completed.count) / 9",systemImage:"chart.bar").font(.title3.bold()).accessibilityIdentifier("cycle-progress")
                ProgressView(value:Double(completed.count),total:9).tint(pine)
                MotionCycleGrid(slots: reference.slots, completed: completed)
            } else { Text("Cycleの計画").font(.headline);Text("計画mdの参照は未設定です").font(.subheadline).foregroundStyle(.secondary) }
            if let reference,let saveReference,!cycles.contains(where:{$0.id==reference.id}) { Button("このCycleを登録") { Task { importMessage=await saveReference(reference) } }.buttonStyle(.borderedProminent) }
            DisclosureGroup("計画mdの管理") {
                VStack(alignment:.leading,spacing:10) {
                    Button("計画mdを参照",systemImage:"doc.text") { importing=true }.buttonStyle(.bordered)
                    Text(saveReference == nil ? "この画面で選んだ計画は表示用です。計画本文や確定実績を書き換えません。":"参照パス・ハッシュ・9枠だけを登録します。計画本文は送信しません。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top,6)
            }.font(.subheadline)
            if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct TrainingSessionPage: View {
    let snapshot: TrainingSnapshot, session: TrainingSession
    var cycles:[TrainingCycleReference]=[]
    var onUpdate:((TrainingSession,TrainingLifecycle,TrainingCycleReference?,TrainingPlanSlot?) async -> String)?=nil
    @State private var cycleID=""
    @State private var slotID=""
    @State private var lifecycle:TrainingLifecycle = .inProgress
    @State private var saving=false
    @State private var saveMessage:String?
    private var cycle:TrainingCycleReference? { cycles.first {$0.id==cycleID} }
    private func exerciseGroups(_ sets: [TrainingSet]) -> [(name: String, sets: [TrainingSet])] {
        var order: [String] = []; var groups: [String: [TrainingSet]] = [:]
        for set in sets { if groups[set.exercise] == nil { order.append(set.exercise) }; groups[set.exercise, default: []].append(set) }
        return order.map { ($0, groups[$0]!.sorted { $0.number < $1.number }) }
    }
    // 「19:05–20:20（75分）」の形。時刻は本人が言ったときだけある（DESIGN 7章）。
    private var sessionTimes: String {
        let start = mockClock(session.startedAt), end = mockClock(session.endedAt)
        let f = ISO8601DateFormatter(), g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parse = { (t: String?) in t.flatMap { f.date(from: $0) ?? g.date(from: $0) } }
        if let start, let end, let a = parse(session.startedAt), let b = parse(session.endedAt) { return "\(start)–\(end)（\(Int(b.timeIntervalSince(a) / 60))分）" }
        if let start { return "開始 \(start) · 終了時刻なし" }
        if let end { return "終了 \(end)" }
        return "時刻の記録なし"
    }
    var body: some View {
        Page(title:session.name) {
            Text(mockDay(session.date)).foregroundStyle(.secondary)
            Text(sessionTimes).font(.caption).foregroundStyle(.secondary)
            if let onUpdate {
                Card {
                    Text("Cycleとセッションの状態").font(.headline)
                    Picker("Cycle",selection:Binding(get:{cycleID},set:{cycleID=$0;slotID=""})) { Text("未設定・追加トレーニング").tag("");ForEach(cycles) { Text($0.name).tag($0.id) } }
                    if let cycle { Picker("予定枠",selection:$slotID) { Text("追加トレーニング").tag("");ForEach(cycle.slots.filter {$0.kind==session.kind}) { Text("\($0.number) · \($0.label)").tag($0.id) } } }
                    Picker("状態",selection:$lifecycle) { Text("予定").tag(TrainingLifecycle.planned);Text("途中").tag(TrainingLifecycle.inProgress);Text("完了").tag(TrainingLifecycle.completed);Text("取消").tag(TrainingLifecycle.cancelled) }
                    Button { guard !saving else { return }; saving=true; Task { saveMessage=await onUpdate(session,lifecycle,cycle,cycle?.slots.first {$0.id==slotID});saving=false } } label: { MotionSaveLabel(title: "状態を保存", busy: saving, saved: saveMessage?.hasPrefix("端末に保存") == true) }.buttonStyle(.borderedProminent).disabled(saving).accessibilityLabel(saving ? "保存中…" : "状態を保存")
                    if let saveMessage { Text(saveMessage).font(.subheadline).foregroundStyle(.secondary) }
                    Text("完了を選んで保存した予定枠だけ、9枠の進捗へ数えます。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("セット").font(.headline)
            let sets = snapshot.sets(in:session)
            if sets.isEmpty { Card { Text("実施セットはまだありません").foregroundStyle(.secondary) } }
            // 種目ごとに1枚へまとめ、開くと各セットが1行（N10）。
            ForEach(Array(exerciseGroups(sets).enumerated()), id: \.element.name) { order, group in
                DisclosureGroup {
                    VStack(spacing: 0) {
                        ForEach(group.sets) { set in
                            HStack { Text("\(set.number)").font(.subheadline).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                                Text("\(set.weightLabel) × \(set.reps)回").font(.body.weight(.medium)); Spacer()
                                Text("RPE " + (set.rpe.map { $0.formatted() } ?? "—")).font(.subheadline).foregroundStyle(set.rpe == nil ? .secondary : .primary)
                            }.padding(.vertical, 8)
                            if set.id != group.sets.last?.id { Divider() }
                        }
                    }.padding(.top, 6)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.headline).foregroundStyle(.primary)
                            if let top = group.sets.max(by: { ($0.weight, $0.reps) < ($1.weight, $1.reps) }) { Text("最大 \(top.weightLabel) × \(top.reps)回").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(); Text("\(group.sets.count)セット").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)).tint(pine).motionReveal(order: order)
            }
            let notes = snapshot.notes(in:session)
            if !notes.isEmpty {
                Text("補足").font(.headline)
                ForEach(TrainingNote.categories.filter { c in notes.contains { $0.category == c } }, id:\.self) { category in
                    Card { Text(category).font(.headline)
                        ForEach(notes.filter { $0.category == category }) { note in VStack(alignment:.leading,spacing:5) { Text(note.speaker == "GPT" ? "GPTの判断・理由":"本人の報告・質問").font(.caption).foregroundStyle(pine)
                            if let exercise=note.exercise { Text(exercise+(note.setNumber.map { " · セット\($0)" } ?? "")).font(.caption).foregroundStyle(.secondary) }
                            Text(note.text).font(.subheadline) } }
                    }
                }
            }
        }.onAppear { cycleID=session.cycleID ?? "";slotID=session.slotID ?? "";lifecycle=session.lifecycle }
    }
}
private struct TrainingSetSummary: View {
    let set:TrainingSet
    var body: some View {
        VStack(alignment:.leading,spacing:7) { Text(set.exercise).font(.headline);Text("セット\(set.number) · \(set.weightLabel) × \(set.reps)回").font(.title3.weight(.semibold))
            Text("RPE \(set.rpe.map {$0.formatted()} ?? "未報告") · RIR \(set.rir.map {String($0)} ?? "未報告")").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct TrainingGradesPage: View {
    let snapshot:TrainingSnapshot
    var date:Date=Date()
    @State private var period=30
    @State private var chartDate:Date?
    @State private var exercise:TrainingExercise = .bench
    @State private var metric:TrainingMetric = .estimatedOneRM
    @State private var seriesID=""
    @State private var selectedPoint:TrainingPoint?
    private var end:String { TrainingDates.string(date) }
    private func seriesLabel(_ s: TrainingSeries) -> String { trainingSeriesLabel(s.id) }
    // 自重は重量・推定1RMがない。補助は補助量が少ないほど強いので推定1RMと自己ベストを出さない。
    private func metricOptions(_ basis: TrainingWeightBasis) -> [(TrainingMetric, String)] {
        switch basis {
        case .standard: [(.weight,"重量×回数"),(.estimatedOneRM,"推定1RM"),(.measuredOneRM,"実測1RM")]
        case .added: [(.weight,"加重×回数"),(.reps,"回数")]
        case .assisted: [(.weight,"補助量"),(.reps,"回数")]
        case .bodyweight: [(.reps,"回数"),(.rpe,"RPE")]
        }
    }
    private var start:String { period == 0 ? "0001-01-01":TrainingDates.string(TrainingDates.calendar.date(byAdding:.day,value:1-period,to:date)!) }
    var body: some View {
        let series = snapshot.series(for: exercise)
        let start = self.start, end = self.end
        let full = series.first { $0.id == seriesID } ?? series.first
        let selected = full?.within(from: start, to: end)
        let points = selected?.points(metric) ?? []
        let bests = full?.personalBestIDs(metric) ?? []
        Page(title:"種目の成績") {
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8) { ForEach(TrainingExercise.allCases) { item in Button { exercise=item;seriesID="";selectedPoint=nil } label: { Text(item.rawValue).font(.subheadline.bold()).frame(maxWidth:.infinity,minHeight:44).background(exercise==item ? pine:Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:12)).foregroundStyle(exercise==item ? Color(uiColor:.systemBackground):Color.primary) }.buttonStyle(.plain) } }
            if series.count>1 { Picker("系列",selection:$seriesID) { ForEach(series) { Text(seriesLabel($0)).tag($0.id) } }.pickerStyle(.menu).onAppear { seriesID=series.first?.id ?? "" } }
            if let last=points.last {
                VStack(spacing:4) {
                    HStack(alignment:.firstTextBaseline,spacing:10) {
                        if metric == .estimatedOneRM { MockFigure(value:last.value.formatted(),unit:"kg",size:44) }
                        else if last.set.basis == .standard { HStack(alignment:.firstTextBaseline,spacing:2) { MockFigure(value:last.set.weight.formatted(),unit:"kg",size:44);Text("×").font(.title2);MockFigure(value:String(last.set.reps),unit:"回",size:44) } }
                        else { Text("\(last.set.weightLabel) × \(last.set.reps)回").font(.system(size:30,weight:.semibold,design:.rounded)) }
                        if bests.contains(last.id) { TrainingPRStamp(key:last.id) }
                    }
                    Text("RPE "+(last.set.rpe.map {$0.formatted()} ?? "未報告")+"  |  "+mockShort(last.date)+(metric == .estimatedOneRM ? "  |  \(last.set.weightLabel) × \(last.set.reps)回から":"")).font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity)
            }
            MotionSegments(title: "指標", selection: $metric, options: metricOptions(full?.basis ?? .standard))
            Menu { Button("回数") { metric = .reps }; Button("RPE") { metric = .rpe } } label: { Text([.reps,.rpe].contains(metric) ? "表示中：\(metric.rawValue)" : "ほかの指標（回数・RPE）").font(.caption) }
            Card {
                if points.isEmpty { ContentUnavailableView("この指標の記録はありません",systemImage:"chart.xyaxis.line",description:Text(metric == .measuredOneRM ? "最大試技・成功を明示した1回だけを表示します。":"欠測を0で埋めず、報告された値だけを表示します。")) }
                else { Chart(points) { point in
                    LineMark(x:.value("日付",TrainingDates.date(point.date)),y:.value(metric.rawValue,point.value)).foregroundStyle(pine)
                    PointMark(x:.value("日付",TrainingDates.date(point.date)),y:.value(metric.rawValue,point.value)).foregroundStyle(bests.contains(point.id) ? prGold:pine).symbolSize(bests.contains(point.id) ? 110:40)
                }.frame(height:210).modifier(MotionChartReveal(key: String(period) + metric.rawValue)).chartXAxis { AxisMarks(values:.automatic(desiredCount:4)) { value in AxisValueLabel { if let date=value.as(Date.self) { Text(TrainingDates.string(date,format:"M/d")) } };AxisGridLine() } }.chartYScale(domain:.automatic(includesZero:false)).chartYAxisLabel([.weight,.measuredOneRM,.estimatedOneRM].contains(metric) ? "kg":metric.rawValue).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .chartXSelection(value:$chartDate)
                    .chartGesture { proxy in
                        SpatialTapGesture().onEnded { value in proxy.selectXValue(at:value.location.x) }
                    }
                    .onChange(of:chartDate) { _, date in
                        guard let date else { return }
                        selectedPoint=points.min { abs(TrainingDates.date($0.date).timeIntervalSince(date)) < abs(TrainingDates.date($1.date).timeIntervalSince(date)) }
                        chartDate=nil
                    }
                }
                MotionSegments(title: "表示期間", selection: $period, options: [(30,"30日"),(90,"90日"),(0,"全期間")])
                HStack(spacing:4) { Text(period == 0 ? "\(mockShort(end))までの全期間":"\(mockShort(start))〜\(mockShort(end))").font(.caption).foregroundStyle(.secondary); MotionInfo(text: "点を押すと、その日の根拠のセットを開きます。日代表は報告値の最大です。補助は補助量を表します。") }
                if metric == .estimatedOneRM { Text("推定1RMはEpley式（通常重量の1〜10回のセット）です。ポーズなどの技術種目は別の系列で、主種目には混ぜません。").font(.caption).foregroundStyle(.secondary) }
                if !bests.isEmpty { Text("大きい金色の点は、それまでの最高を上回った自己ベストの日です。").font(.caption).foregroundStyle(.secondary) }
            }
            if let target=full?.nextTarget() {
                Card {
                    Text("次回の目安").font(.headline)
                    Text("\(target.weight.formatted())kg × \(target.reps)回").font(.title2.bold()).foregroundStyle(target.raise ? prGold:pine)
                    Text(target.reason).font(.caption).foregroundStyle(.secondary)
                    Text("計画mdに指定があれば、そちらを優先してください。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let selected, !selected.sets.isEmpty {
                Text("最近のセット").font(.headline)
                let recent = Array(selected.sets.suffix(12).reversed())
                MockRows {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("日付").fixedSize().frame(minWidth: 52, alignment: .leading)
                            Text("重量 × 回数").fixedSize()
                            Spacer()
                            Text("RPE").fixedSize()
                        }
                        Text("日付 / 重量 × 回数 / RPE").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,16).padding(.top,12).padding(.bottom,6)
                    ForEach(Array(recent.enumerated()), id:\.element.id) { index, set in
                        Button { if let p = points.first(where:{ $0.id == set.id }) { selectedPoint = p } } label: {
                            VStack(spacing:0) {
                                ViewThatFits(in: .horizontal) {
                                    HStack {
                                        Text(mockShort(selected.dates[set.id] ?? "")).font(.subheadline).foregroundStyle(.secondary).fixedSize().frame(minWidth:52,alignment:.leading)
                                        Text("\(set.weightLabel) × \(set.reps)回").font(.body.weight(.medium)).fixedSize()
                                        Spacer()
                                        Text(set.rpe.map {$0.formatted()} ?? "未報告").font(.subheadline).foregroundStyle(set.rpe == nil ? .secondary : .primary).fixedSize()
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(mockShort(selected.dates[set.id] ?? "")).font(.subheadline).foregroundStyle(.secondary)
                                        Text("\(set.weightLabel) × \(set.reps)回").font(.body.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                                        HStack {
                                            Text("RPE").foregroundStyle(.secondary)
                                            Text(set.rpe.map {$0.formatted()} ?? "未報告").foregroundStyle(set.rpe == nil ? .secondary : .primary)
                                        }.font(.subheadline)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.horizontal,16).padding(.vertical,11)
                                if index < recent.count-1 { Divider().padding(.leading,16) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .onChange(of:"\(exercise.rawValue)/\(metric.rawValue)/\(seriesID)/\(period)") { _, _ in selectedPoint=nil;chartDate=nil }
        // 重量の種類が変わったら、その種類で使える指標へ切り替える（自重の懸垂は回数から）。
        .onChange(of:"\(exercise.rawValue)/\(seriesID)") { _, _ in
            let basis = (snapshot.series(for:exercise).first { $0.id == seriesID } ?? snapshot.series(for:exercise).first)?.basis ?? .standard
            let allowed = metricOptions(basis).map(\.0) + [.reps, .rpe]
            if !allowed.contains(metric) { metric = metricOptions(basis).first?.0 ?? .reps }
        }
        .sheet(item:$selectedPoint) { point in NavigationStack { Page(title:"根拠セット") { Text(mockDay(point.date)).foregroundStyle(.secondary);Card { TrainingSetSummary(set:point.set) };Text("この確定セットがグラフの点の根拠です。").font(.caption).foregroundStyle(.secondary) }.toolbar { ToolbarItem(placement:.confirmationAction) { Button("閉じる") { selectedPoint=nil } } } } }
    }
}

extension String { func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self } }
/// 系列ID「種目／重量基準／機器／変種」を人が読む名前へ。標準・通常・機器未記録は書かない（例：「ポーズ」「加重」「通常」）。
func trainingSeriesLabel(_ id: String) -> String {
    let parts = id.split(separator:"／").map(String.init)
    guard parts.count == 4 else { return id }
    return [parts[3] == "標準" ? nil : parts[3], parts[1] == "通常" ? nil : parts[1], parts[2] == "機器未記録" ? nil : parts[2]].compactMap { $0 }.joined(separator:"・").ifEmpty("通常")
}
private let prGold = Color(red:0.80, green:0.58, blue:0.10)

// M09：自己ベストの日だけ、スタンプが押される。表示ごとに1回だけ動き、視差効果を減らす設定では止まる。
private struct TrainingPRStamp: View {
    let key: String
    private var policy = MotionPolicy()
    @State private var landed = false
    init(key: String) { self.key = key }
    var body: some View {
        Text("自己ベスト").font(.caption.bold()).foregroundStyle(prGold)
            .padding(.horizontal,8).padding(.vertical,3)
            .overlay(RoundedRectangle(cornerRadius:6).stroke(prGold,lineWidth:2))
            .rotationEffect(.degrees(-8))
            .scaleEffect(landed ? 1 : 1.7).opacity(landed ? 1 : 0)
            .task(id: key) {
                landed = policy.reduced
                guard !policy.reduced else { return }
                withAnimation(Motion.animation(reduceMotion: false)) { landed = true }
                Haptics.emit(.success)
            }
            .accessibilityLabel("自己ベスト")
    }
}
