import Foundation
import PHHHubCore
import SwiftUI

private struct SleepTrainingChoice: Identifiable {
    let id: String, wakeDate: String, sourceID: String, sourceName: String, start: Date, end: Date
    let healthWindowID: String?, autoSleep: AutoSleepRecord?
}

struct SleepTrainingInsightsPage: View {
    let hub: HubStore, date: String
    var autoSleep: [AutoSleepDelivery] = []
    @AppStorage("trainingInsights.t06.majorSeries") private var majorSeriesJSON = "{}"
    @State private var period = 30
    @State private var selectedSource = ""
    @State private var initialSourceSelected = false
    @State private var selectedWindows: [String: String] = [:]
    @State private var mainSleepIDs: Set<String> = []
    @State private var choices: [SleepTrainingChoice] = []
    @State private var report: SleepTrainingInsightsReport?
    @State private var message = ""

    var body: some View {
        HubMockPage(title: "睡眠とトレーニング成績", showNavigation: true) {
            HubMockCard {
                Text("睡眠と成績を並べて確認").font(.headline)
                Text("選択した睡眠区間と、同じ起床日の主系列の成績を並べます。区間の時刻と取得元を確認できます。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("表示期間", selection: $period) {
                    Text("30日").tag(30); Text("90日").tag(90); Text("全期間").tag(0)
                }.pickerStyle(.segmented)
                let sources = sourceNames
                if !sources.isEmpty {
                    Picker("睡眠の取得元", selection: $selectedSource) {
                        Text("未選択").tag("")
                        ForEach(sources.keys.sorted(), id: \.self) { id in Text(sources[id] ?? id).tag(id) }
                    }.pickerStyle(.menu).accessibilityIdentifier("sleep-training-source")
                }
            }
            if let report {
                HubMockCard {
                    Text("関係の判定は準備中").font(.headline)
                    Text(report.assessmentReason).font(.subheadline).foregroundStyle(.secondary)
                    Text("睡眠と成績の値がある記録：\(report.comparableCount)件／対象の実施日：\(report.observedTrainingDays)日")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("同時に変わっていても、睡眠が成績を変えたとは断定しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("sleep-training-assessment-pending")
                HubMockCard {
                    Text("成績を比べる主系列").font(.headline)
                    ForEach(TrainingExercise.allCases) { exercise in
                        let options = report.availableTrainingSeries.filter { $0.exercise == exercise }
                        if !options.isEmpty {
                            Picker(exercise.rawValue, selection: majorSelection(exercise)) {
                                Text("未選択").tag("")
                                ForEach(options) { Text(seriesLabel($0.id)).tag($0.id) }
                            }.pickerStyle(.menu)
                        }
                    }
                    Text("負荷を落とす週の見直しと同じ主系列を使います。技術種目・機器の違いを混ぜません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if report.comparisons.isEmpty {
                    HubMockCard { Text("主系列を選択し、対象期間の完了した実績を確認してください。").font(.subheadline).foregroundStyle(.secondary) }
                }
                ForEach(report.comparisons) { comparison in comparisonCard(comparison) }
            }
            if !message.isEmpty { HubMockCard { Text(message).font(.subheadline).foregroundStyle(.secondary) } }
            Button("端末の記録で再確認") { reload() }.accessibilityIdentifier("sleep-training-refresh")
        }
        .task(id: date) { reload() }
        .onChange(of: period) { _, _ in reload() }
        .onChange(of: selectedSource) { _, _ in selectedWindows = [:]; mainSleepIDs = []; reload() }
        .onChange(of: majorSeriesJSON) { _, _ in reload() }
    }

    @ViewBuilder private func comparisonCard(_ comparison: SleepTrainingComparison) -> some View {
        HubMockCard {
            Text("\(mockDay(comparison.date)) · \(comparison.exercise.rawValue)").font(.headline)
            Text(seriesLabel(comparison.seriesID)).font(.caption).foregroundStyle(.secondary)
            let options = choices.filter { $0.wakeDate == comparison.date && $0.sourceID == selectedSource }
            if !options.isEmpty {
                Picker("睡眠区間", selection: windowSelection(comparison.date, options: options)) {
                    Text("未選択").tag("")
                    ForEach(options) { Text("\(clock($0.start)) 〜 \(clock($0.end))").tag($0.id) }
                }.pickerStyle(.menu)
            }
            if let night = comparison.sleep {
                Text(night.mainSleepConfirmed && !comparison.issues.contains(.sleepAfterTraining) ? "前夜の主睡眠" : "選択した睡眠区間")
                    .font(.subheadline.bold())
                Text("\(sleepDuration(night.actualSleepSeconds)) · \(night.sourceName)").font(.title3.bold())
                Text("\(clock(night.start)) 〜 \(clock(night.end))").font(.caption).foregroundStyle(.secondary)
                if !night.mainSleepConfirmed {
                    Button("この区間を前夜の主睡眠として表示") { mainSleepIDs.insert(night.id); reload() }
                        .font(.caption).disabled(comparison.issues.contains(.sleepAfterTraining))
                } else {
                    Button("主睡眠の確認を戻す") { mainSleepIDs.remove(night.id); reload() }.font(.caption)
                }
            } else { Text("睡眠区間の選択待ち").font(.subheadline).foregroundStyle(.secondary) }
            if let point = comparison.performance {
                Text("当日の推定1RM：\(point.value.formatted()) kg").font(.title3.bold()).foregroundStyle(pine)
                Text("根拠：\(point.set.weightLabel) × \(point.set.reps)回（セット\(point.set.number)・成功報告あり）")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("成績の根拠が不足しています。").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(comparison.issues, id: \.rawValue) { issue in Text(issue.title).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityIdentifier("sleep-training-comparison")
    }

    private var sourceNames: [String: String] {
        choices.reduce(into: [:]) { $0[$1.sourceID] = $1.sourceName }
    }
    private var majorSelections: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(majorSeriesJSON.utf8))) ?? [:]
    }
    private func majorSelection(_ exercise: TrainingExercise) -> Binding<String> {
        .init(get: { majorSelections[exercise.rawValue] ?? "" }, set: { id in
            var selected = majorSelections
            if id.isEmpty { selected.removeValue(forKey: exercise.rawValue) } else { selected[exercise.rawValue] = id }
            if let data = try? JSONEncoder().encode(selected), let json = String(data: data, encoding: .utf8) { majorSeriesJSON = json }
        })
    }
    private func selectedChoice(_ day: String, options: [SleepTrainingChoice]) -> SleepTrainingChoice? {
        if let id = selectedWindows[day] { return options.first { $0.id == id } }
        return options.count == 1 ? options.first : nil
    }
    private func windowSelection(_ day: String, options: [SleepTrainingChoice]) -> Binding<String> {
        .init(get: { selectedChoice(day, options: options)?.id ?? "" }, set: { id in selectedWindows[day] = id; reload() })
    }
    private func seriesLabel(_ id: String) -> String { trainingSeriesLabel(id) }
    private func clock(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.timeZone = HealthDates.calendar.timeZone
        formatter.dateFormat = "M/d H:mm"; return formatter.string(from: value)
    }
    private func reload() {
        do {
            let rows = try ["TrainingSessions", "TrainingSets", "TrainingNotes"].flatMap { try hub.rows(table: $0) }
            let snapshot = try TrainingSnapshot(rows: rows)
            let dateParts = date.split(separator: "-").compactMap { Int($0) }
            guard FoodDates.text(FoodDates.date(date)) == date, dateParts.count == 3,
                  let asOf = HealthDates.calendar.date(from: .init(year: dateParts[0], month: dateParts[1], day: dateParts[2]))
            else { throw SleepTrainingFailure.invalidValue }
            let from = period == 0 ? nil : HealthDates.calendar.date(byAdding: .day, value: 1 - period, to: asOf).map(HealthDates.local)
            let days = Set(snapshot.sessions.filter { $0.lifecycle == .completed && $0.date <= date && (from == nil || $0.date >= from!) }.map(\.date))
            var samples: [HealthSample] = []
            for day in days.sorted() {
                let page = try hub.healthRecords(metric: .sleepAnalysis, date: day, limit: 500)
                guard !page.hasMore else { throw SleepTrainingFailure.invalidValue }
                samples += page.records.compactMap(\.sample)
            }
            let healthChoices = try SleepTrainingInsights.healthWindows(samples, asOf: date).map {
                SleepTrainingChoice(id: $0.id, wakeDate: $0.wakeDate, sourceID: $0.sourceID, sourceName: $0.sourceName,
                                    start: $0.start, end: $0.end, healthWindowID: $0.id, autoSleep: nil)
            }
            let autoChoices = autoSleep.compactMap { delivery -> SleepTrainingChoice? in
                guard let record = delivery.normalization.record, record.dictionary == .timeAsleep,
                      days.contains(record.targetDate), let interval = record.interval else { return nil }
                return .init(id: record.id, wakeDate: record.targetDate, sourceID: "autosleep.shortcuts.timeAsleep",
                             sourceName: "AutoSleep・ショートカット", start: interval.start, end: interval.end,
                             healthWindowID: nil, autoSleep: record)
            }
            choices = healthChoices + autoChoices
            if !initialSourceSelected, !sourceNames.isEmpty {
                initialSourceSelected = true
                let sources = sourceNames
                if sources["autosleep.shortcuts.timeAsleep"] != nil { selectedSource = "autosleep.shortcuts.timeAsleep" }
                else if sources.count == 1 { selectedSource = sources.keys.first! }
            }
            var nights: [SleepTrainingNight] = []
            for day in days.sorted() {
                let options = choices.filter { $0.wakeDate == day && $0.sourceID == selectedSource }
                guard let choice = selectedChoice(day, options: options) else { continue }
                if let record = choice.autoSleep { nights.append(try .autoSleep(record, mainSleepConfirmed: mainSleepIDs.contains(choice.id))) }
                else if let id = choice.healthWindowID {
                    nights.append(try .health(samples: samples, sourceID: choice.sourceID, windowID: id, mainSleepConfirmed: mainSleepIDs.contains(choice.id)))
                }
            }
            let major = Dictionary(uniqueKeysWithValues: majorSelections.compactMap { key, id -> (TrainingExercise, String)? in
                guard let exercise = TrainingExercise(rawValue: key), !id.isEmpty else { return nil }; return (exercise, id)
            })
            report = try SleepTrainingInsights.evaluate(rows: rows, asOf: date, from: from,
                                                        majorSeries: major, sleepNights: nights,
                                                        sleepSourceID: selectedSource.isEmpty ? nil : selectedSource)
            message = ""
        } catch { report = nil; message = "対象の睡眠と成績を確認できません。\(error.localizedDescription)" }
    }
}
