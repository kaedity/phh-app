import PHHHubCore
import SwiftUI

/// 目標の詳細から開く読取専用の見直し画面。確認日は端末内だけに保存します。
struct EnergyReviewPage: View {
    let hub: HubStore, planning: PlanningScreenModel, health: HealthScreenModel, date: String
    @AppStorage("energyReview.g02.lastReviewedOn") private var lastReviewedOn = ""
    @AppStorage("energyReview.g02.lastInitialAdjustmentReviewedOn") private var lastInitialAdjustmentReviewedOn = ""
    @State private var morningConfirmed = false
    @State private var report: EnergyReviewReport?
    @State private var sourceNames: [String: String] = [:]
    @State private var message = ""
    @State private var currentBaseKcal: Double?

    var body: some View {
        HubMockPage(title: "カロリーの見直し", showNavigation: true) {
            HubMockCard {
                Text("週1回の見直し").font(.headline)
                Text("記録完了の日の摂取量と、朝の体重から見直しを提案します。初期目標の増減は2週間ごとに確認します。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !sourceNames.isEmpty {
                    Menu {
                        ForEach(sourceNames.keys.sorted(), id: \.self) { id in
                            Button(sourceNames[id] ?? id) { health.selectedWeightSource = id }
                        }
                    } label: {
                        Label(sourceNames[health.selectedWeightSource ?? ""] ?? "体重の取得元を選択", systemImage: "scalemass")
                    }.accessibilityIdentifier("energy-review-source")
                }
                Toggle("表示する体重は、朝の起床後・トイレ後・飲食前に測った値です", isOn: $morningConfirmed)
                    .font(.subheadline).accessibilityIdentifier("energy-review-morning-confirmation")
                Text("体重の時刻から測定条件を推測せず、この確認がある測定だけを使います。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let report {
                proposalCard(report)
                evidenceCards(report)
                if !report.reasons.isEmpty {
                    HubMockCard {
                        Text("確認すること").font(.headline)
                        ForEach(report.reasons, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                if !report.excludedDays.isEmpty {
                    HubMockCard {
                        Text("計算に使わなかった日").font(.headline)
                        ForEach(report.excludedDays) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(day.date).font(.subheadline.bold())
                                Text(day.reasons.map(\.title).joined(separator: "・")).font(.caption).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    }.accessibilityIdentifier("energy-review-excluded-days")
                }
            }
            if !message.isEmpty {
                HubMockCard { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            }
            Button("端末の記録で再計算") { morningConfirmed = false; reload() }
                .accessibilityIdentifier("energy-review-refresh")
        }
        .task(id: date) { morningConfirmed = false; reload() }
        .onChange(of: morningConfirmed) { _, _ in reload() }
        .onChange(of: health.selectedWeightSource) { _, _ in morningConfirmed = false; reload() }
    }

    @ViewBuilder private func proposalCard(_ report: EnergyReviewReport) -> some View {
        HubMockCard {
            Text(report.proposal == nil ? "今回の見直し" : "見直しの提案").font(.headline)
            if let proposal = report.proposal {
                Text(proposalTitle(proposal.kind)).font(.title3.bold()).foregroundStyle(pine)
                if let range = proposal.targetKcal {
                    Text("\(kcalRange(range)) kcal / 日").font(.title2.bold())
                } else if let range = proposal.adjustmentKcal {
                    Text("調整の幅 \(kcalRange(range)) kcal / 日").font(.title3.bold())
                }
                if let currentBaseKcal {
                    Text("現在の基準：\(foodNumber(currentBaseKcal)) kcal / 日").font(.subheadline).foregroundStyle(.secondary)
                }
                Text(proposal.reason).font(.subheadline)
                Text("採用する場合の適用開始日：\(proposal.proposedEffectiveFrom)").font(.caption).foregroundStyle(.secondary)
                Text("目標はご自身で変更できます。この提案では目標やPFCを変更しません。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("今回の提案を確認しました") {
                    lastReviewedOn = report.reviewedOn
                    if proposal.kind != .measuredTarget { lastInitialAdjustmentReviewedOn = report.reviewedOn }
                    reload()
                }.accessibilityIdentifier("energy-review-acknowledge")
            } else {
                Text(report.weeklyReviewDue ? "計算の条件と対象日の記録を確認してください。" : "今週の確認は済んでいます。")
                    .font(.subheadline)
                if !report.weeklyReviewDue {
                    Text("次回の確認：\(report.nextWeeklyReviewOn)").font(.subheadline).foregroundStyle(pine)
                }
            }
        }.accessibilityIdentifier("energy-review-proposal")
    }

    @ViewBuilder private func evidenceCards(_ report: EnergyReviewReport) -> some View {
        HubMockCard {
            Text("対象期間").font(.headline)
            Text("\(report.context.start) 〜 \(report.context.end)").font(.subheadline)
            Text("条件を満たした日：\(report.eligibleDates.count) / \(report.context.dayCount)日。今日の途中の記録は含めません。")
                .font(.caption).foregroundStyle(.secondary)
            if let trend = report.initialTrend {
                Text("初期目標の確認に使う7日平均").font(.subheadline.bold())
                weightAverage(trend.before)
                weightAverage(trend.after)
                Text("週あたり \(signed(trend.weeklyChangeKilograms)) kg（\(signed(trend.weeklyChangePercent)) %）")
                    .font(.subheadline)
                Text("増え方の目安は週0.25〜0.5%。初期目標の増減条件は週0.1kg未満・0.5kg以上です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let maintenance = report.maintenance {
            HubMockCard {
                Text("実測からの維持量の推定").font(.headline)
                Text("\(foodNumber(maintenance.estimatedMaintenanceKcal)) kcal / 日").font(.title2.bold())
                Text("摂取の参照：\(maintenance.period.start) 〜 \(maintenance.period.end)（\(maintenance.period.dayCount)日）")
                    .font(.subheadline)
                Text("平均摂取：\(foodNumber(maintenance.averageIntakeKcal)) kcal / 日").font(.subheadline)
                weightAverage(maintenance.trend.before)
                weightAverage(maintenance.trend.after)
                Text("維持量 ≒ 平均摂取 − 体重変化 × 7,700 ÷ 日数")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(foodNumber(maintenance.averageIntakeKcal)) − (\(signed(maintenance.trend.changeKilograms)) × 7,700 ÷ \(maintenance.trend.elapsedDays))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("前後7日平均の中央日間と、摂取の対象期間をそろえています。活動エネルギーを追加で加算しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }.accessibilityIdentifier("energy-review-maintenance")
        }
    }

    private func weightAverage(_ average: EnergyReviewWeightAverage) -> some View {
        Text("\(average.period.start) 〜 \(average.period.end)：\(average.kilograms.formatted(.number.precision(.fractionLength(2)))) kg")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func proposalTitle(_ kind: EnergyReviewProposalKind) -> String {
        switch kind {
        case .measuredTarget: "実測に合わせた目標の候補"
        case .increase: "基準を100〜150kcal増やす候補"
        case .decrease: "基準を100〜150kcal減らす候補"
        case .keep: "現在の基準を継続する候補"
        }
    }
    private func kcalRange(_ range: EnergyReviewKcalRange) -> String {
        range.lower == range.upper ? foodNumber(range.lower) : "\(foodNumber(range.lower))〜\(foodNumber(range.upper))"
    }
    private func signed(_ value: Double) -> String {
        (value > 0 ? "+" : "") + value.formatted(.number.precision(.fractionLength(2)))
    }

    private func reload() {
        do {
            try planning.refresh()
            let dates = try EnergyReview.contextDates(asOf: date), pending = try hub.pending()
            let goal = try planning.goal(date)
            let rule = goal.flatMap { daily in planning.records.compactMap { $0.mutation.goalRule }.first { $0.id == daily.ruleID && $0.revision == daily.ruleRevision } }
            guard !pending.contains(where: { $0.operation.planning?.goalRule != nil }) else {
                throw FoodFailure.pendingEdit
            }
            var intakeDays: [EnergyReviewIntakeDay] = [], samples: [HealthSample] = []
            for day in dates {
                let page = try hub.healthRecords(metric: .bodyMass, date: day, limit: 500)
                guard !page.hasMore else { throw EnergyReviewFailure.invalidValue }
                samples += page.records.compactMap(\.sample)
                guard let completed = planning.foodDay(day) else { continue }
                let summaries = try hub.rows(table: "DailySummary", date: day).filter(\.active)
                guard summaries.count <= 1 else { throw HubError.invalidResponse }
                let consumed = try planning.consumedWithSupplements(planningConsumed(summary: summaries.first), date: day)
                let mealIDs = Set(try hub.rows(table: "Meals", date: day).map(\.entityID))
                let changing = pending.contains { entry in
                    let operation = entry.operation, mutation = operation.planning
                    return operation.foodMeal?.date == day || operation.payload?.local_date == day ||
                        mealIDs.contains(operation.entity_id) || mutation?.foodDay?.date == day || mutation?.day?.date == day ||
                        mutation?.plan != nil || mutation?.product != nil
                }
                intakeDays.append(try .init(day: completed, kcal: consumed.kcal, hasPendingChanges: changing))
            }
            var names: [String: String] = [:]
            for sample in samples { names[sample.source.id] = sample.source.name }
            sourceNames = names
            let weightDays = try HealthPresentation.weightDays(samples, sourceID: health.selectedWeightSource ?? "")
                .map { try EnergyReviewWeightDay(healthDay: $0, morningMeasurementConfirmed: morningConfirmed) }
            report = try EnergyReview.evaluate(asOf: date, goal: rule, intakeDays: intakeDays, weights: weightDays,
                                               lastReviewedOn: lastReviewedOn.isEmpty ? nil : lastReviewedOn,
                                               lastInitialAdjustmentReviewedOn: lastInitialAdjustmentReviewedOn.isEmpty ? nil : lastInitialAdjustmentReviewedOn)
            currentBaseKcal = rule?.base.kcal; message = ""
        } catch {
            report = nil
            message = "対象の記録を確認できません。未確定の変更がある場合は、その確定後に再計算してください。\(error.localizedDescription)"
        }
    }
}
