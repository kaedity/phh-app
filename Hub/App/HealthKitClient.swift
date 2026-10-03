import Foundation
import HealthKit
import PHHHubCore

/// 製品の読取設定が有効になるまで認可もクエリも実行しません。
@MainActor final class HealthKitClient: HealthImportClient {
    let healthStore = HKHealthStore()
    var readingEnabled = false
    static func quantityType(_ metric: HealthMetric) throws -> HKQuantityType {
        let identifier: HKQuantityTypeIdentifier
        switch metric {
        case .bodyMass: identifier = .bodyMass
        case .bodyFatPercentage: identifier = .bodyFatPercentage
        case .bodyMassIndex: identifier = .bodyMassIndex
        case .leanBodyMass: identifier = .leanBodyMass
        case .stepCount: identifier = .stepCount
        case .activeEnergyBurned: identifier = .activeEnergyBurned
        case .basalEnergyBurned: identifier = .basalEnergyBurned
        case .sleepAnalysis: throw HealthFailure.invalidValue
        }
        return HKQuantityType(identifier)
    }
    static func type(_ metric: HealthMetric) throws -> HKSampleType {
        metric == .sleepAnalysis ? HKCategoryType(.sleepAnalysis) : try quantityType(metric)
    }
    static func unit(_ metric: HealthMetric) throws -> HKUnit {
        switch metric {
        case .bodyMass, .leanBodyMass: .gramUnit(with: .kilo)
        case .bodyFatPercentage: .percent()
        case .bodyMassIndex, .stepCount: .count()
        case .activeEnergyBurned, .basalEnergyBurned: .kilocalorie()
        case .sleepAnalysis: throw HealthFailure.invalidValue
        }
    }
    func requestReadAuthorization(metrics: Set<HealthMetric>) async throws {
        guard HKHealthStore.isHealthDataAvailable(), !metrics.isEmpty else { throw HealthClientFailure.unavailable }
        let types = try Set<HKObjectType>(metrics.map(Self.type))
        try await healthStore.requestAuthorization(toShare: [], read: types)
        // UI完了は全種類の読取許可を意味しません。
    }
    private func checkEnabled() throws {
        guard readingEnabled else { throw HealthClientFailure.unavailable }
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthClientFailure.unavailable }
    }
    private func decodeAnchor(_ data: Data?) throws -> HKQueryAnchor? {
        guard let data else { return nil }
        do {
            guard let anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) else { throw HealthClientFailure.invalidAnchor }
            return anchor
        } catch { throw HealthClientFailure.invalidAnchor }
    }
    private func source(_ sample: HKSample) throws -> HealthSource {
        let revision = sample.sourceRevision
        return try HealthSource(id: revision.source.bundleIdentifier, name: revision.source.name, device: revision.productType ?? sample.device?.model)
    }
    private func quantity(_ sample: HKQuantitySample, metric: HealthMetric) throws -> HealthSample {
        try HealthSample(id: sample.uuid.uuidString, metric: metric, source: source(sample), start: sample.startDate, end: sample.endDate,
                         value: sample.quantity.doubleValue(for: Self.unit(metric)), unit: metric.unit)
    }
    private func sleep(_ sample: HKCategorySample) throws -> HealthSample {
        let stage: HealthSleepStage
        switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
        case .inBed: stage = .inBed
        case .awake: stage = .awake
        case .asleepUnspecified: stage = .asleep
        case .asleepCore: stage = .core
        case .asleepDeep: stage = .deep
        case .asleepREM: stage = .rem
        default: throw HealthFailure.invalidValue
        }
        return try HealthSample(id: sample.uuid.uuidString, metric: .sleepAnalysis, source: source(sample), start: sample.startDate, end: sample.endDate,
                                value: nil, unit: "interval", sleepStage: stage)
    }
    func page(scope: HealthQueryScope, anchor: Data?, limit: Int) async throws -> HealthImportPage {
        try checkEnabled(); try scope.validate()
        guard limit > 0, limit <= 500 else { throw HealthFailure.invalidValue }
        let decoded = try decodeAnchor(anchor)
        let predicate = HKQuery.predicateForSamples(withStart: scope.lowerBound, end: scope.upperBound,
                                                   options: scope.metric == .sleepAnalysis ? [] : .strictStartDate)
        let added: [HealthSample], deleted: [String], next: HKQueryAnchor
        if scope.metric == .sleepAnalysis {
            let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)], anchor: decoded, limit: limit)
            let result = try await descriptor.result(for: healthStore)
            added = try result.addedSamples.map(sleep); deleted = result.deletedObjects.map { $0.uuid.uuidString.lowercased() }; next = result.newAnchor
        } else {
            let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: try Self.quantityType(scope.metric), predicate: predicate)], anchor: decoded, limit: limit)
            let result = try await descriptor.result(for: healthStore)
            added = try result.addedSamples.map { try quantity($0, metric: scope.metric) }; deleted = result.deletedObjects.map { $0.uuid.uuidString.lowercased() }; next = result.newAnchor
        }
        let data = try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true)
        return HealthImportPage(scopeID: scope.id, expectedAnchor: anchor, nextAnchor: data, added: added, deletedIDs: deleted,
                                hasMore: added.count + deleted.count == limit, receivedAt: Date())
    }
    func statistics(metric: HealthMetric, date: String) async throws -> HealthDailyStatistics {
        try checkEnabled(); guard metric.isCumulative else { throw HealthFailure.invalidValue }
        let values = date.split(separator: "-").compactMap { Int($0) }, calendar = HealthDates.calendar
        guard values.count == 3, let start = calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2])), HealthDates.local(start) == date,
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw HealthFailure.invalidValue }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        var interval = DateComponents(day: 1); interval.calendar = calendar; interval.timeZone = calendar.timeZone
        let descriptor = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: try Self.quantityType(metric), predicate: predicate),
                                                               options: .cumulativeSum, anchorDate: start, intervalComponents: interval)
        let collection = try await descriptor.result(for: healthStore)
        let value = collection.statistics(for: start)?.sumQuantity()?.doubleValue(for: try Self.unit(metric))
        return try HealthDailyStatistics(metric: metric, date: date, value: value, measuredAt: Date())
    }
}
