import Foundation
import Observation

extension HealthMetric {
    public var title: String {
        switch self {
        case .bodyMass:"体重"; case .bodyFatPercentage:"体脂肪率"; case .bodyMassIndex:"BMI"; case .leanBodyMass:"除脂肪体重"
        case .stepCount:"歩数"; case .activeEnergyBurned:"活動消費"; case .basalEnergyBurned:"安静時消費"; case .sleepAnalysis:"睡眠"
        }
    }
    public var displayUnit: String { self == .bodyFatPercentage ? "%" : self == .bodyMassIndex ? "" : self == .stepCount ? "歩" : unit }
    public func displayValue(_ value: Double) -> Double { self == .bodyFatPercentage ? value * 100 : value }
}
@MainActor @Observable public final class HealthScreenModel {
    private let store: HubStore
    public private(set) var weightSamples: [HealthSample] = []
    public private(set) var sleepSamples: [HealthSample] = []
    public private(set) var hasMoreSleep = false
    public private(set) var bodySamples: [HealthMetric: [HealthSample]] = [:]
    public private(set) var dailyStatistics: [HealthMetric: HealthDailyStatistics] = [:]
    public private(set) var dirtyStatistics: [HealthMetric: Set<String>] = [:]
    public private(set) var progress: [HealthImportProgress] = []
    public private(set) var weightTotalCount = 0
    public private(set) var hasMoreWeight = false
    public private(set) var date: String
    public private(set) var message = "まだ取得していません"
    public var selectedWeightSource: String?
    public var selectedSleepSource: String?
    public init(store: HubStore, date: String) throws { self.store = store; self.date = date; try refresh(date: date) }
    public func refresh(date: String) throws {
        guard Schema.validDate(date) else { throw HealthFailure.invalidValue }
        do {
            let weights = try store.healthRecords(metric: .bodyMass), sleeps = try store.healthRecords(metric: .sleepAnalysis, limit:500)
            let scopes = try store.healthScopes()
            var body: [HealthMetric: [HealthSample]] = [:], statistics: [HealthMetric: HealthDailyStatistics] = [:], dirty: [HealthMetric: Set<String>] = [:]
            for metric in [HealthMetric.bodyFatPercentage, .bodyMassIndex, .leanBodyMass] { body[metric] = try store.healthRecords(metric: metric).records.compactMap(\.sample) }
            for metric in [HealthMetric.stepCount, .activeEnergyBurned, .basalEnergyBurned] { statistics[metric] = try store.healthStatistics(metric: metric, date: date); dirty[metric] = Set(try store.healthDirtyDays(metric:metric,limit:500).map(\.date)) }
            // 取得が全て成功したときだけ表示用の状態をまとめて切り替えます。
            self.date = date; weightSamples = weights.records.compactMap(\.sample); sleepSamples = sleeps.records.compactMap(\.sample); hasMoreSleep = sleeps.hasMore
            weightTotalCount = weights.totalCount; hasMoreWeight = weights.hasMore; progress = scopes; bodySamples = body; dailyStatistics = statistics; dirtyStatistics = dirty
            if selectedWeightSource == nil { selectedWeightSource = weightSamples.first(where: { $0.value != nil })?.source.id }
            if selectedSleepSource == nil {
                selectedSleepSource = sleepSamples.first(where: { $0.source.name.localizedCaseInsensitiveContains("AutoSleep") })?.source.id ?? sleepSamples.first?.source.id
            }
            message = scopes.isEmpty ? "健康データの接続は準備中です" : scopes.contains(where: { $0.readState == .temporaryFailure || $0.readState == .unavailable }) ? "取得できていない項目があります。前回値を保持しています。" : "端末で受け取った記録を表示しています"
        } catch { message = "取得内容を確認できません。前回の表示を保持しています。"; throw error }
    }
    public func loadMoreWeight() throws {
        guard hasMoreWeight else { return }
        let page = try store.healthRecords(metric: .bodyMass, offset: weightSamples.count)
        let incoming = page.records.compactMap(\.sample)
        guard Set((weightSamples + incoming).map(\.id)).count == weightSamples.count + incoming.count else { throw HealthFailure.invalidValue }
        weightSamples += incoming; weightTotalCount = page.totalCount; hasMoreWeight = page.hasMore
    }
    public var weightSources: [HealthSource] { uniqueSources(weightSamples) }
    public var sleepSources: [HealthSource] { uniqueSources(sleepSamples) }
    private func uniqueSources(_ samples: [HealthSample]) -> [HealthSource] { Array(Dictionary(samples.map { ($0.source.id, $0.source) }, uniquingKeysWith: { a,_ in a }).values).sorted { $0.name < $1.name } }
    public var latestWeight: HealthSample? { weightSamples.first { $0.source.id == selectedWeightSource && $0.value != nil } }
    public var selectedWeightSamples: [HealthSample] { weightSamples.filter { $0.source.id == selectedWeightSource } }
    public var weightDays: [HealthWeightDay] { HealthPresentation.weightDays(weightSamples, sourceID: selectedWeightSource ?? "") }
    public var oldestLoadedDate: String? { weightSamples.last.map { HealthDates.local($0.start) } }
    public func latestBody(_ metric: HealthMetric) -> HealthSample? { bodySamples[metric]?.first { $0.value != nil } }
    public func readState(_ metric: HealthMetric) -> HealthReadState {
        let matches = progress.filter { $0.scope.metric == metric }
        if matches.contains(where: { $0.readState == .temporaryFailure }) { return .temporaryFailure }
        if matches.contains(where: { $0.readState == .unavailable }) { return .unavailable }
        return matches.contains(where: { $0.readState == .available }) ? .available : .noDataOrNotAuthorized
    }
    public var historyImporting: Bool { progress.contains { $0.scope.phase == .history && !$0.complete } }
    // 元データに明示されたinBed/asleep区間を使います。段階の隙間から主睡眠を推定しません。
    public var currentSleepWindow: HealthSample? {
        let sourceSamples = sleepSamples.filter { $0.source.id == selectedSleepSource }
        let beds = sourceSamples.filter { $0.sleepStage == .inBed }
        let windows = beds + sourceSamples.filter { sample in
            sample.sleepStage == .asleep && !beds.contains { $0.start <= sample.start && $0.end >= sample.end }
        }
        // その日に終わった区間のうち最も長いものを主睡眠とする。昼寝が後に終わっても主睡眠を置き換えない（10/4）。
        return windows.filter { HealthDates.local($0.end) == date }.max { ($0.end.timeIntervalSince($0.start), $0.end) < ($1.end.timeIntervalSince($1.start), $1.end) }
    }
    public var currentSleep: HealthSleepSession? {
        guard let window = currentSleepWindow else { return nil }
        return try? HealthPresentation.sleep(sleepSamples, sourceID: window.source.id, start: window.start, end: window.end, classification: .unclassified)
    }
}
