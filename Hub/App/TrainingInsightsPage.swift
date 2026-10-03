import Foundation
import PHHHubCore
import SwiftUI

struct TrainingInsightsPage: View {
    let hub: HubStore, date: String
    @AppStorage("trainingInsights.t06.majorSeries") private var majorSeriesJSON = "{}"
    @AppStorage("trainingInsights.t06.benchDefaultInitialized") private var benchDefaultInitialized = false
    @State private var report: TrainingInsightsReport?
    @State private var message = ""

    var body: some View {
        HubMockPage(title: "負荷を落とす週の見直し", showNavigation: true) {
            HubMockCard {
                Text("主要種目の推定1RMで確認").font(.headline)
                Text("同じ系列の成功セットで、推定1RMが前回から3回続けて伸びなければ、負荷を落とす週を提案します。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("重量や回数の変更量は未設定です。計画を確認して、ご自身で判断できます。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("確認する日：\(date)").font(.caption).foregroundStyle(.secondary)
            }
            if let report {
                HubMockCard {
                    Text("主種目として確認する系列").font(.headline)
                    Text("選択は端末内に保存します。機器や技術種目が異なる系列を合算しません。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(TrainingExercise.allCases) { exercise in
                        let options = report.availableSeries.filter { $0.exercise == exercise }
                        if !options.isEmpty {
                            Picker(exercise.rawValue, selection: selection(for: exercise)) {
                                Text("未選択").tag("")
                                ForEach(options) { option in Text(seriesLabel(option.id)).tag(option.id) }
                            }.pickerStyle(.menu).accessibilityIdentifier("training-insight-major-\(exercise.id)")
                        }
                    }
                    if !report.unselectedExercises.isEmpty {
                        Text("系列が未選択の種目：\(report.unselectedExercises.map(\.rawValue).joined(separator: "・"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(report.assessments) { assessment in assessmentCard(assessment) }
                if report.availableSeries.isEmpty {
                    HubMockCard { Text("主要種目の実績はまだありません。").font(.subheadline).foregroundStyle(.secondary) }
                }
                HubMockCard {
                    Text("使う記録と方法").font(.headline)
                    Text("完了セッションの、成功を明示した通常重量・1〜10回のセットから、既存のEpley式で推定します。同日の最大値を1回として比べます。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("3回の比較には4実施日分が必要です。途中の不明値を飛ばして、離れた記録を連続させません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("懸垂の自重・加重・補助には、この停滞条件を適用しません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !message.isEmpty {
                HubMockCard { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            }
            Button("端末の記録で再確認") { reload() }.accessibilityIdentifier("training-insights-refresh")
        }
        .task(id: date) { reload() }
        .onChange(of: majorSeriesJSON) { _, _ in reload() }
    }

    @ViewBuilder private func assessmentCard(_ assessment: TrainingDeloadAssessment) -> some View {
        HubMockCard {
            Text(assessment.exercise.rawValue).font(.headline)
            Text(seriesLabel(assessment.id)).font(.caption).foregroundStyle(.secondary)
            Label(stateTitle(assessment), systemImage: assessment.isSuggested ? "arrow.down.forward.circle" : "chart.line.uptrend.xyaxis")
                .font(.title3.bold()).foregroundStyle(assessment.isSuggested ? Color.orange : pine)
            Text(assessment.reason).font(.subheadline)
            if assessment.remainingObservations > 0, assessment.state == .insufficientHistory {
                Text("判定まであと\(assessment.remainingObservations)実施日分").font(.subheadline).foregroundStyle(pine)
            }
            ForEach(assessment.observations) { point in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(mockDay(point.date)) · 推定1RM \(point.value.formatted()) kg").font(.subheadline.bold())
                    Text("根拠：\(point.set.weightLabel) × \(point.set.reps)回（セット\(point.set.number)）")
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
            if !assessment.missingEvidenceDates.isEmpty {
                Text("条件を満たす根拠がない日：\(assessment.missingEvidenceDates.joined(separator: "・"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if assessment.isSuggested {
                Text("この表示から計画や実績は変更されません。").font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("training-deload-assessment")
    }

    private func stateTitle(_ assessment: TrainingDeloadAssessment) -> String {
        switch assessment.state {
        case .suggested: "負荷を落とす週を検討する候補"
        case .growing: "連続停滞の条件には当たりません"
        case .insufficientHistory: "実績を蓄積中"
        case .missingEvidence: "根拠の記録を確認してください"
        case .unsupportedBasis: "この系列の判定方法は未設定"
        case .unavailableSeries: "完了した実績がありません"
        }
    }
    private var selections: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(majorSeriesJSON.utf8))) ?? [:]
    }
    private func selection(for exercise: TrainingExercise) -> Binding<String> {
        .init(get: { selections[exercise.rawValue] ?? "" }, set: { id in
            var values = selections
            if id.isEmpty { values.removeValue(forKey: exercise.rawValue) } else { values[exercise.rawValue] = id }
            if exercise == .bench { benchDefaultInitialized = true }
            saveSelections(values)
        })
    }
    private func saveSelections(_ values: [String: String]) {
        guard let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) else { return }
        majorSeriesJSON = json
    }
    private func seriesLabel(_ id: String) -> String { trainingSeriesLabel(id) }
    private func reload() {
        do {
            let rows = try ["TrainingSessions", "TrainingSets", "TrainingNotes"].flatMap { try hub.rows(table: $0) }
            let major = Dictionary(uniqueKeysWithValues: selections.compactMap { key, id -> (TrainingExercise, String)? in
                guard let exercise = TrainingExercise(rawValue: key), !id.isEmpty else { return nil }
                return (exercise, id)
            })
            let next = try TrainingInsights.evaluate(rows: rows, asOf: date, majorSeries: major)
            report = next; message = ""
            // 本人合意済みのベンチ初期主種目。標準/未報告の変種をタッチアンドゴーへ読み替えません。
            if !benchDefaultInitialized, selections[TrainingExercise.bench.rawValue] == nil {
                let candidates = next.availableSeries.filter {
                    $0.exercise == .bench && $0.basis == .standard && $0.id.split(separator: "／").last == "タッチアンドゴー"
                }
                if candidates.count == 1 {
                    benchDefaultInitialized = true
                    var values = selections; values[TrainingExercise.bench.rawValue] = candidates[0].id
                    saveSelections(values)
                }
            }
        } catch {
            report = nil; message = "記録を確認できません。前回の記録との比較は保留しています。\(error.localizedDescription)"
        }
    }
}
