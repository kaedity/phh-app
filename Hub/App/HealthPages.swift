import SwiftUI
import Charts
import PHHHubCore

/// 体重は桁をそろえて小数1桁で表示する（68 → 68.0）。
private func weightText(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—" }
private func healthNumber(_ value: Double?, digits: Int = 1) -> String { value.map { $0.formatted(.number.precision(.fractionLength(0...digits))) } ?? "—" }
func sleepDuration(_ seconds: Double?) -> String {
    guard let seconds else { return "—" }; let minutes = Int(seconds / 60)
    return "\(minutes / 60)時間\(minutes % 60)分"
}
private func healthTime(_ date: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "M/d HH:mm"; return f.string(from:date) }
private func stateTitle(_ state: HealthReadState) -> String {
    switch state { case .available:"取得あり"; case .unavailable:"利用不可"; case .temporaryFailure:"一時取得失敗・前回値"; case .noDataOrNotAuthorized:"データなしまたは未許可" }
}
struct HealthHomeCard: View {
    @Namespace private var cardZoom
    private var motion = MotionPolicy()
    let screen: HealthScreenModel
    var autoSleep: [AutoSleepDelivery] = []
    var readEnabled = false
    var readPrepared = false
    var connect: (() async -> Void)?
    var refresh: (() async -> Void)?
    var body: some View {
        Card {
            HStack { Label("からだと活動", systemImage: "heart").font(.headline); Spacer(); NavigationLink { HealthDetailPage(screen: screen, autoSleep: autoSleep, readEnabled: readEnabled, readPrepared: readPrepared, connect: connect, refresh: refresh) } label: { Text("詳しく").font(.subheadline) } }
            AccessibleRow(spacing: 20) {
                NavigationLink { HealthWeightPage(screen: screen).motionZoom(id: "weight", in: cardZoom, reduced: motion.reduced) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("体重").font(.caption).foregroundStyle(.secondary)
                        Text("\(healthNumber(screen.latestWeight?.value)) kg").font(.title2.weight(.semibold)).foregroundStyle(.primary)
                        if let weight = screen.latestWeight { Text(weight.source.name).font(.caption).foregroundStyle(.secondary); Text(healthTime(weight.start)).font(.caption2).foregroundStyle(.secondary) }
                        else { Text("測定値がありません").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).matchedTransitionSource(id: "weight", in: cardZoom).accessibilityIdentifier("health-weight-link")
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text("睡眠").font(.caption).foregroundStyle(.secondary)
                    let latest = autoSleep.filter { $0.targetDate == screen.date && $0.dictionary == .timeAsleep && $0.normalization.record?.actualSleepSeconds != nil }.max { $0.receivedAt < $1.receivedAt }
                    Text(sleepDuration(latest?.normalization.record?.actualSleepSeconds ?? screen.currentSleep?.seconds)).font(.title3.weight(.semibold))
                    Text(latest != nil ? "AutoSleep · 実睡眠" : screen.currentSleep == nil ? "取得した区間がありません" : "取得区間 · 主睡眠/昼寝は未分類").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            AccessibleRow(spacing: 15) {
                ForEach([HealthMetric.stepCount, .activeEnergyBurned, .basalEnergyBurned], id: \.self) { metric in
                    VStack(alignment: .leading, spacing: 6) { Text(metric.title).font(.caption).foregroundStyle(.secondary); Text("\(healthNumber(screen.dailyStatistics[metric]?.value, digits: 0)) \(metric.displayUnit)").font(.subheadline.weight(.semibold)); if screen.dirtyStatistics[metric]?.contains(screen.date) == true { Text("更新待ち").font(.caption2).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if screen.historyImporting { Label("履歴を取り込み中", systemImage: "clock").font(.caption).foregroundStyle(.secondary); MotionSkeleton() }
            Text(screen.message).font(.caption).foregroundStyle(.secondary)
        }
    }
}
private struct WeightChartPoint: Identifiable { let day: HealthWeightDay; let date: Date; let segment: Int; var id: String { day.representativeID } }
struct HealthWeightPage: View {
    let screen: HealthScreenModel
    @State private var period = 30
    @State private var selectedDate: Date?
    @State private var message: String?
    private var points: [WeightChartPoint] {
        let cutoff = period == 0 ? nil : HealthDates.calendar.date(byAdding: .day, value: -(period-1), to: FoodDates.date(screen.date))
        var last: Date?, segment = 0
        return screen.weightDays.compactMap { day in
            let date = FoodDates.date(day.date); if let cutoff, date < cutoff { return nil }
            if let last, HealthDates.calendar.dateComponents([.day], from: last, to: date).day != 1 { segment += 1 }
            last = date; return WeightChartPoint(day: day, date: date, segment: segment)
        }
    }
    private var averagePoints: [(date: String, value: Double)] {
        let shown = Set(points.map(\.day.date)); return HealthPresentation.weightAverages(screen.weightDays).filter { shown.contains($0.date) }
    }
    // 増量の判断は7日平均で行う（DESIGN 6章）。目安は週に体重の+0.25〜0.5%。
    @ViewBuilder private var weightTrendLine: some View {
        if let trend = HealthPresentation.weightTrend(screen.weightDays, end: screen.date) {
            HStack(spacing: 6) {
                Text("7日平均 \(weightText(trend.average)) kg").font(.subheadline.weight(.semibold))
                if let change = trend.change, let pct = trend.percentPerWeek {
                    Text("先週比 \(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(2)))) kg（\(pct >= 0 ? "+" : "")\(pct.formatted(.number.precision(.fractionLength(1))))%/週）").font(.subheadline)
                        .foregroundStyle(pct >= 0.25 && pct <= 0.5 ? pine : .secondary)
                }
            }.padding(.top, 4)
            Text(trend.change == nil ? "先週の測定が5日未満のため、変化はまだ出せません" : "増量の目安：週に+0.25〜0.5%（7日平均の点線）").font(.caption2).foregroundStyle(.secondary)
        } else {
            Text("7日平均は、7日のうち5日以上測ると表示します").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
        }
    }
    var body: some View {
        Page(title: "体重") {
            MotionSegments(title: "表示期間", selection: $period, options: [(7,"7日"),(30,"30日"),(0,"全期間")])
            VStack(spacing: 4) {
                MockFigure(value: weightText(screen.latestWeight?.value), unit: "kg", size: 52)
                if let sample = screen.latestWeight { Text(mockDayTime(sample.start)).font(.subheadline).foregroundStyle(.secondary); Text("\(sample.source.name)経由").font(.caption).foregroundStyle(pine) }
                if screen.readState(.bodyMass) != .available { Text(stateTitle(screen.readState(.bodyMass))).font(.caption).foregroundStyle(.secondary) }
                weightTrendLine
            }.frame(maxWidth: .infinity)
            Card {
                if points.isEmpty { ContentUnavailableView("測定値がありません", systemImage: "scalemass", description: Text("欠測は0 kgとして扱いません。")) }
                else {
                    Chart {
                        ForEach(points) { point in
                        RuleMark(x: .value("日付", point.date), yStart: .value("最小", point.day.minimum), yEnd: .value("最大", point.day.maximum)).foregroundStyle(pine.opacity(0.3))
                        LineMark(x: .value("日付", point.date), y: .value("代表値", point.day.value), series: .value("系列", "測定\(point.segment)")).foregroundStyle(pine)
                        PointMark(x: .value("日付", point.date), y: .value("代表値", point.day.value)).foregroundStyle(pine).symbolSize(28)
                        }
                        ForEach(averagePoints, id: \.date) { avg in
                            LineMark(x: .value("日付", FoodDates.date(avg.date)), y: .value("7日平均", avg.value), series: .value("系列", "7日平均")).foregroundStyle(pfcFat.opacity(0.85)).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        }
                    }.chartXScale(range: .plotDimension(padding: 14)).chartYScale(domain: .automatic(includesZero: false), range: .plotDimension(padding: 14)).chartYAxisLabel("kg").chartXSelection(value: $selectedDate).dynamicTypeSize(...DynamicTypeSize.xxxLarge).frame(height: 200).modifier(MotionChartReveal(key: String(period)))
                    if let selectedDate, let nearest = points.min(by: { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }) {
                        Text("\(mockDay(nearest.day.date)) · \(weightText(nearest.day.value)) kg · 範囲 \(weightText(nearest.day.minimum))–\(weightText(nearest.day.maximum)) kg").font(.caption)
                    }
                    HStack(spacing: 4) { Text("点はその日の朝いちばんの測定です").font(.caption).foregroundStyle(.secondary); MotionInfo(text: "縦線はその日に読み込んだ測定の範囲です。測っていない日は線をつなぎません。") }
                }
            }
            HStack { Text("測定履歴").font(.headline); Spacer()
                if screen.weightSources.count > 1 { Menu { ForEach(screen.weightSources, id: \.id) { source in Button(source.name) { screen.selectedWeightSource = source.id } } } label: { Label("取得元", systemImage: "chevron.up.chevron.down").font(.caption) } }
            }
            let samples = Array(screen.selectedWeightSamples)
            if !samples.isEmpty {
                MockRows { ForEach(Array(samples.enumerated()), id: \.element.id) { index, sample in
                    VStack(spacing: 0) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                Text(mockDayTime(sample.start)).font(.body.weight(.medium)).fixedSize()
                                Spacer(minLength: 8)
                                Text("\(weightText(sample.value)) kg").font(.body.weight(.semibold)).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mockDayTime(sample.start)).font(.body.weight(.medium))
                                Text("\(weightText(sample.value)) kg").font(.body.weight(.semibold)).fixedSize(horizontal: true, vertical: false)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.horizontal, 16).padding(.vertical, 13)
                        if index < samples.count-1 { Divider().padding(.leading, 16) }
                    }
                } }
            }
            if screen.hasMoreWeight { Button("前の測定を読み込む") { do { try screen.loadMoreWeight() } catch { message = "履歴を取得できませんでした。表示済みの測定は保持しています。" } }.buttonStyle(.bordered).frame(maxWidth: .infinity) }
            if let oldest = screen.oldestLoadedDate { Text("読み込み済みの最古日：\(mockDay(oldest))").font(.caption).foregroundStyle(.secondary) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct HealthDetailPage: View {
    let screen: HealthScreenModel
    var autoSleep: [AutoSleepDelivery] = []
    var readEnabled = false
    var readPrepared = false
    var connect: (() async -> Void)?
    var refresh: (() async -> Void)?
    var body: some View {
        Page(title: "健康データ") {
            Card {
                Label("HealthKitへの接続", systemImage: "heart.text.clipboard").font(.headline)
                Text(screen.message).font(.subheadline).foregroundStyle(.secondary)
                if let connect, readPrepared && !readEnabled { Button("読み取りを許可する") { Task { await connect() } }.buttonStyle(.borderedProminent) }
                if let refresh, readEnabled { Button("最新の健康データを確認") { Task { await refresh() } }.buttonStyle(.bordered) }
                Text("測定値は元のアプリで管理されます。ここでは取得した写しを表示します。").font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink { HealthWeightPage(screen: screen) } label: { Card { HStack { Label("体重と測定履歴", systemImage: "scalemass").font(.headline); Spacer(); Image(systemName: "chevron.right") } } }.buttonStyle(.plain)
            Card {
                Text("体組成").font(.headline)
                ForEach([HealthMetric.bodyFatPercentage, .bodyMassIndex, .leanBodyMass], id: \.self) { metric in
                    let sample = screen.latestBody(metric)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(metric.title); Spacer(); Text("\(healthNumber(sample?.value.map(metric.displayValue))) \(metric.displayUnit)").fontWeight(.semibold) }
                        if let sample { Text("\(sample.source.name) · \(healthTime(sample.start))").font(.caption).foregroundStyle(.secondary) }
                        Text(stateTitle(screen.readState(metric))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Card {
                Text("\(mockDay(screen.date))の活動").font(.headline)
                ForEach([HealthMetric.stepCount, .activeEnergyBurned, .basalEnergyBurned], id: \.self) { metric in
                    let statistic = screen.dailyStatistics[metric]
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(metric.title); Spacer(); Text("\(healthNumber(statistic?.value, digits: 0)) \(metric.displayUnit)").fontWeight(.semibold) }
                        Text("HealthKitの統計値 · \(statistic.map { healthTime($0.measuredAt) } ?? "未取得")").font(.caption).foregroundStyle(.secondary)
                        Text(screen.dirtyStatistics[metric]?.contains(screen.date) == true ? "前回値・更新待ち" : stateTitle(screen.readState(metric))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("目標への活動補正はオフです。").font(.caption).foregroundStyle(.secondary)
            }
            Card {
                Text("睡眠").font(.headline)
                if !screen.sleepSources.isEmpty { Picker("睡眠の情報源", selection: Binding(get: { screen.selectedSleepSource ?? "" }, set: { screen.selectedSleepSource = $0 })) { ForEach(screen.sleepSources, id: \.id) { Text($0.name).tag($0.id) } }.pickerStyle(.menu) }
                Text(sleepDuration(screen.currentSleep?.seconds)).font(.title2.weight(.semibold))
                Text("区間の終了日：\(mockDay(screen.date))").font(.caption).foregroundStyle(.secondary)
                Text(stateTitle(screen.readState(.sleepAnalysis))).font(.caption).foregroundStyle(.secondary)
                if screen.hasMoreSleep { Text("表示は最新500区間です。前の区間は未読込です。").font(.caption).foregroundStyle(.secondary) }
                if let window = screen.currentSleepWindow { Text("採用した元区間：\(healthTime(window.start)) – \(healthTime(window.end))").font(.caption).foregroundStyle(.secondary) }
                else { Text("主睡眠の区間を確定できていません。段階の一覧は元の区間のまま表示します。").font(.caption).foregroundStyle(.secondary) }
                ForEach(screen.sleepSamples.filter { $0.source.id == screen.selectedSleepSource && HealthDates.local($0.end) == screen.date }) { sample in
                    Text("\(healthTime(sample.start)) – \(healthTime(sample.end)) · \(sample.sleepStage?.rawValue ?? "不明")").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !autoSleep.isEmpty {
                Card {
                    Text("AutoSleepの補完").font(.headline)
                    ForEach(autoSleep.filter { $0.targetDate == screen.date }.sorted { $0.receivedAt > $1.receivedAt }) { delivery in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(mockDay(delivery.targetDate)) · \(delivery.dictionary.rawValue)").font(.subheadline.weight(.semibold))
                            Text("実睡眠 \(sleepDuration(delivery.normalization.record?.actualSleepSeconds))").font(.subheadline)
                            Text(delivery.normalization.record == nil ? "要確認・原辞書を端末に保持" : "端末保存・独自指標は別に保持").font(.caption).foregroundStyle(.secondary)
                            if !delivery.normalization.issues.isEmpty { Text("未対応・単位未確認など \(delivery.normalization.issues.count)項目").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Card {
                Text("取得状態").font(.headline)
                ForEach(screen.progress, id: \.scope.id) { progress in
                    VStack(alignment: .leading, spacing: 5) { Text("\(progress.scope.metric.title) · \(progress.scope.phase == .recent ? "最近の記録" : "履歴")").font(.subheadline.weight(.semibold)); Text("\(stateTitle(progress.readState)) · \(progress.complete ? "取得済み" : "取り込み中")").font(.caption).foregroundStyle(.secondary); Text("対象開始日 \(HealthDates.local(progress.scope.lowerBound))").font(.caption).foregroundStyle(.secondary) }
                }
                if screen.progress.isEmpty { Text("まだ健康データを接続していません").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }
}
