import Foundation

@MainActor public protocol HealthImportClient: AnyObject {
    func page(scope: HealthQueryScope, anchor: Data?, limit: Int) async throws -> HealthImportPage
    func statistics(metric: HealthMetric, date: String) async throws -> HealthDailyStatistics
}
public enum HealthClientFailure: Error, Equatable { case unavailable, temporaryFailure, invalidAnchor }
public enum HealthImportIssue: String, Sendable { case queryFailed, storageFailed, statisticsFailed, cancelled }
public struct HealthImportOutcome: Equatable, Sendable {
    public var pages = 0, statistics = 0
    public var needsMore = false
    public var issues: [HealthImportIssue] = []
    public init() {}
}
public struct HealthDirtyDay: Codable, Equatable, Identifiable, Sendable {
    public let metric: HealthMetric, date: String, id: String
}

/// HealthKitと同じ順序を合成クライアントでも実行します。Google通信は待ちません。
@MainActor public final class HealthImportPipeline {
    private let store: HubStore, client: any HealthImportClient
    private let synthetic: Bool
    private var flights: [HealthMetric: Task<HealthImportOutcome, Never>] = [:]
    private var notified: Set<HealthMetric> = []
    public init(store: HubStore, client: any HealthImportClient, synthetic: Bool = false) {
        self.store = store; self.client = client; self.synthetic = synthetic
    }
    /// 同指標の通知は同じ処理へ合流し、それぞれのcompletionを一度だけ返します。
    public func catchUp(metric: HealthMetric, maxPages: Int = 8, completion: (() -> Void)? = nil) async -> HealthImportOutcome {
        defer { completion?() }
        guard maxPages > 0, maxPages <= 100 else { var result = HealthImportOutcome(); result.issues = [.queryFailed]; return result }
        if let flight = flights[metric] {
            notified.insert(metric)
            try? store.markHealthCatchUpPending(metric: metric)
            return await flight.value
        }
        let flight = Task { await self.drain(metric: metric, maxPages: maxPages) }
        flights[metric] = flight
        let result = await flight.value
        flights[metric] = nil
        return result
    }
    public func cancel(metric: HealthMetric) { flights[metric]?.cancel() }
    private func drain(metric: HealthMetric, maxPages: Int) async -> HealthImportOutcome {
        var result = HealthImportOutcome()
        do {
            let scopes = try store.healthScopes().filter { $0.scope.metric == metric }.sorted {
                if $0.scope.phase != $1.scope.phase { return $0.scope.phase == .recent }
                return $0.scope.id < $1.scope.id
            }.map(\.scope)
            repeat {
                notified.remove(metric)
                for scope in scopes {
                    var hasMore = true
                    while hasMore, result.pages < maxPages {
                        try Task.checkCancellation()
                        guard let progress = try store.healthProgress(scope.id) else { throw HealthFailure.invalidScope }
                        let page: HealthImportPage
                        do { page = try await client.page(scope: scope, anchor: progress.anchor, limit: 500) }
                        catch {
                            let state: HealthReadState = (error as? HealthClientFailure) == .unavailable ? .unavailable : .temporaryFailure
                            try? store.markHealthReadFailure(scope.id, state: state)
                            result.issues.append(error is CancellationError ? .cancelled : .queryFailed)
                            result.needsMore = true; return result
                        }
                        try Task.checkCancellation()
                        do {
                            guard page.scopeID == scope.id, page.expectedAnchor == progress.anchor else { throw HealthFailure.invalidScope }
                            _ = try store.ingestHealth(page, synthetic: synthetic)
                        } catch {
                            try? store.markHealthReadFailure(scope.id, state: .temporaryFailure)
                            result.issues.append(.storageFailed); result.needsMore = true; return result
                        }
                        result.pages += 1; hasMore = page.hasMore
                    }
                    if hasMore { result.needsMore = true }
                    if result.pages == maxPages { break }
                }
                if result.pages == maxPages { result.needsMore = result.needsMore || notified.contains(metric); break }
            } while notified.contains(metric)
            // 再開待ちはDBのcomplete/dirtyに残ります。全指標の完了へ一般化しません。
            if try store.healthScopes().contains(where: { $0.scope.metric == metric && !$0.complete }) { result.needsMore = true }
            if metric.isCumulative {
                for dirty in try store.healthDirtyDays(metric: metric, limit: 100) {
                    try Task.checkCancellation()
                    do {
                        let statistic = try await client.statistics(metric: metric, date: dirty.date)
                        try Task.checkCancellation()
                        if try store.commitHealthStatistics(statistic, dirty: dirty, synthetic: synthetic) { result.statistics += 1 }
                        else { result.needsMore = true }
                    } catch {
                        if error is CancellationError { throw error }
                        result.issues.append(.statisticsFailed); result.needsMore = true
                    }
                }
                if try !store.healthDirtyDays(metric: metric, limit: 1).isEmpty { result.needsMore = true }
            }
            if notified.contains(metric) { result.needsMore = true }
        } catch {
            for progress in (try? store.healthScopes()) ?? [] where progress.scope.metric == metric {
                try? store.markHealthReadFailure(progress.scope.id, state: .temporaryFailure)
            }
            result.issues.append(error is CancellationError ? .cancelled : .storageFailed); result.needsMore = true
        }
        return result
    }
}
