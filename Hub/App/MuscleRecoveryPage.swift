import Foundation
import PHHHubCore
import SwiftUI

struct MuscleRecoveryPage: View {
    let snapshot: TrainingSnapshot
    var asOf: Date = Date()
    @AppStorage("muscleRecovery.t03.exerciseMappings") private var mappingsJSON = "[]"
    @State private var report: MuscleRecoveryReport?
    @State private var editing: MuscleExerciseMapping?
    @State private var message = ""
    @State private var currentTime: Date?

    var body: some View {
        HubMockPage(title: "部位と前回の実施", showNavigation: true) {
            HubMockCard {
                Text("部位ごとに前回の実施を確認").font(.headline)
                Text("種目と部位の対応から、実施セットがある最新の日を表示します。終了時刻の報告があれば終了から、開始だけなら開始からの経過を表示します。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let report {
                HubMockCard {
                    Text("回復率・次回可能時刻は保留").font(.headline)
                    Text(report.pendingReason).font(.subheadline).foregroundStyle(.secondary)
                    Text("経過時間だけで、回復状態や次の実施可否を決めません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("確認時刻：\(clock(report.asOf))").font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("muscle-recovery-pending")
                ForEach(report.activities) { activity in activityCard(activity) }
                if report.activities.isEmpty {
                    HubMockCard { Text("対応する部位の実施記録はまだありません。").font(.subheadline).foregroundStyle(.secondary) }
                }
                HubMockCard {
                    Text("種目と部位の対応").font(.headline)
                    Text("初期候補は一般的な対象部位です。ご自身の種目・動作に合わせて変更できます。変更は端末内に保存します。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.mappings) { mapping in
                        VStack(alignment: .leading, spacing: 5) {
                            Button { editing = mapping } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(mapping.exercise).font(.subheadline.bold())
                                        Text(mapping.regions.isEmpty ? "部位が未設定" : mapping.regions.map(\.rawValue).joined(separator: "・"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "pencil").font(.caption)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("muscle-mapping-edit")
                            Text(mapping.origin == .generalCandidate ? "初期候補" : "本人設定").font(.caption2).foregroundStyle(.secondary)
                            if let address = mapping.sourceURL, let url = URL(string: address) {
                                Link("初期候補の出典：ACE公式", destination: url).font(.caption)
                            }
                        }
                    }
                    if !report.unmappedExercises.isEmpty {
                        Text("未設定：\(report.unmappedExercises.joined(separator: "・"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !message.isEmpty { HubMockCard { Text(message).font(.subheadline).foregroundStyle(.secondary) } }
            Button("現在の時刻で再計算") { currentTime = Date(); reload() }.accessibilityIdentifier("muscle-recovery-refresh")
        }
        .task { reload() }
        .onChange(of: mappingsJSON) { _, _ in reload() }
        .sheet(item: $editing) { mapping in
            NavigationStack {
                MuscleMappingEditor(mapping: mapping) { regions in saveMapping(mapping.exercise, regions: regions) }
            }
        }
    }

    @ViewBuilder private func activityCard(_ activity: MuscleRegionActivity) -> some View {
        HubMockCard {
            Text(activity.region.rawValue).font(.headline)
            Text("前回の実施日：\(mockDay(activity.latestDate))").font(.subheadline)
            if let seconds = activity.elapsedSeconds, let time = activity.referenceTime {
                Text("\(activity.timeBasis == .ended ? "終了" : "開始")から\(elapsed(seconds))")
                    .font(.title3.bold()).foregroundStyle(pine)
                Text("報告時刻：\(clock(time))").font(.caption).foregroundStyle(.secondary)
            } else { Text("時刻を確定できないため、実施日だけを表示します。").font(.caption).foregroundStyle(.secondary) }
            if let issue = activity.timeIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            ForEach(activity.evidence) { evidence in
                VStack(alignment: .leading, spacing: 3) {
                    Text(evidence.exercises.joined(separator: "・")).font(.subheadline)
                    Text("対象セット：\(evidence.setIDs.count)件").font(.caption).foregroundStyle(.secondary)
                    if let time = evidence.referenceTime {
                        Text("\(evidence.timeBasis == .ended ? "終了" : "開始") \(clock(time))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
        }.accessibilityIdentifier("muscle-region-activity")
    }
    private func clock(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.timeZone = HealthDates.calendar.timeZone
        formatter.dateFormat = "M/d H:mm"; return formatter.string(from: value)
    }
    private func elapsed(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        if hours >= 48 { return "\(hours / 24)日\(hours % 24)時間" } // 2日以上は日で読む（成績・ホームと同じ区切り）
        return hours == 0 ? "\(Int(seconds / 60))分" : "\(hours)時間\(Int(seconds / 60) % 60)分"
    }
    private func reload() {
        do {
            let saved = try JSONDecoder().decode([MuscleExerciseMapping].self, from: Data(mappingsJSON.utf8))
            report = try MuscleRecovery.evaluate(snapshot: snapshot, asOf: currentTime ?? asOf, overrides: saved)
            message = ""
        } catch { report = nil; message = "部位の対応と実施記録を確認できません。\(error.localizedDescription)" }
    }
    private func saveMapping(_ exercise: String, regions: [MuscleRegion]) {
        do {
            var saved = try JSONDecoder().decode([MuscleExerciseMapping].self, from: Data(mappingsJSON.utf8))
            saved.removeAll { $0.exercise == exercise }
            saved.append(try .init(exercise: exercise, regions: regions, origin: .userDefined))
            let data = try JSONEncoder().encode(saved.sorted { $0.exercise < $1.exercise })
            guard let json = String(data: data, encoding: .utf8) else { throw HubError.invalidResponse }
            mappingsJSON = json; editing = nil
        } catch { message = "対応表を保存できません。\(error.localizedDescription)" }
    }
}

private struct MuscleMappingEditor: View {
    let mapping: MuscleExerciseMapping, save: ([MuscleRegion]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<MuscleRegion>
    init(mapping: MuscleExerciseMapping, save: @escaping ([MuscleRegion]) -> Void) {
        self.mapping = mapping; self.save = save; _selected = State(initialValue: Set(mapping.regions))
    }
    var body: some View {
        Form {
            Section(mapping.exercise) {
                ForEach(MuscleRegion.allCases) { region in
                    Toggle(region.rawValue, isOn: .init(get: { selected.contains(region) }, set: { include in
                        if include { selected.insert(region) } else { selected.remove(region) }
                    }))
                }
            }
            Section { Text("選択を空にすると、この種目を部位の集計へ入れません。トレーニングの記録や計画は変更しません。") }
        }.navigationTitle("部位の対応を変更").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("端末に保存") { save(MuscleRegion.allCases.filter(selected.contains)) }
                        .accessibilityIdentifier("muscle-mapping-save")
                }
            }
    }
}
