import Foundation

public enum SyncTimingStage: String, Codable, CaseIterable, Sendable {
    case queueRead = "queue_read", operationResolve = "operation_resolve", operationCommit = "operation_commit"
    case deltaFetch = "delta_fetch", deltaApply = "delta_apply", retryWait = "retry_wait"
    case authentication = "authentication", requestEncoding = "request_encoding", http = "http", responseDecoding = "response_decoding"
}
public struct SyncTimingMetric: Codable, Equatable, Sendable {
    public let stage: SyncTimingStage
    public let elapsedSeconds: Double
    public let calls: Int
    public let itemCount: Int
    public let requestBytes: Int
    public let responseBytes: Int
}
/// 固定の工程名・時間・件数/バイト数だけ。本文、URL、ID、認証情報は受け付けません。
@MainActor public final class SyncTimingRecorder {
    public struct Token { fileprivate let stage: SyncTimingStage; fileprivate let started: Double }
    private let clock: () -> Double
    private var values: [SyncTimingStage: SyncTimingMetric] = [:]
    public init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    public var metrics: [SyncTimingMetric] { SyncTimingStage.allCases.compactMap { values[$0] } }
    public func reset() { values = [:] }
    public func begin(_ stage: SyncTimingStage) -> Token { .init(stage: stage, started: clock()) }
    public func end(_ token: Token, items: Int = 0, requestBytes: Int = 0, responseBytes: Int = 0) {
        let old = values[token.stage], elapsed = max(0, clock() - token.started)
        guard elapsed.isFinite else { return }
        values[token.stage] = .init(stage: token.stage, elapsedSeconds: (old?.elapsedSeconds ?? 0) + elapsed,
            calls: (old?.calls ?? 0) + 1, itemCount: (old?.itemCount ?? 0) + max(0, items),
            requestBytes: (old?.requestBytes ?? 0) + max(0, requestBytes), responseBytes: (old?.responseBytes ?? 0) + max(0, responseBytes))
    }
    public func measure<T>(_ stage: SyncTimingStage, items: Int = 0, _ work: () throws -> T) rethrows -> T {
        let token = begin(stage); defer { end(token, items: items) }; return try work()
    }
}
