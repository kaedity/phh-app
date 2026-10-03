import Foundation
@MainActor public protocol HubTransport: AnyObject {
    var connected: Bool { get }
    func resolve(_ operation: HubOperation) async throws -> Receipt
    func syncDelta(_ query: HubQuery, date: String) async throws -> Delta
    func result(_ operation: HubOperation) async throws -> Receipt
    func submit(_ operation: HubOperation) async throws -> Receipt
    func processIntake(date: String) async throws
    func delta(_ query: HubQuery) async throws -> Delta
}
@MainActor public extension HubTransport {
    func resolve(_ operation: HubOperation) async throws -> Receipt {
        let receipt = try await result(operation); try receipt.validate(for: operation)
        return receipt.status == "not_found" ? try await submit(operation) : receipt
    }
    func syncDelta(_ query: HubQuery, date: String) async throws -> Delta {
        try await processIntake(date: date); return try await delta(query)
    }
}
@MainActor public final class SyncEngine {
    public private(set) var busy = false
    public private(set) var message = "まだ同期していません"
    public private(set) var lastFailureCode: String?
    public private(set) var lastFailureStage: String?
    public let timing = SyncTimingRecorder()
    private let store: HubStore; private let transport: any HubTransport
    private let retryWait: @MainActor (UInt64) async throws -> Void
    public init(store: HubStore, transport: any HubTransport, retryWait: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.store = store; self.transport = transport; self.retryWait = retryWait
    }
    public func synchronize(date: String, now: Date = .now, forceQueued: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        lastFailureCode = nil; lastFailureStage = nil; timing.reset()
        var stage = "connection"
        do {
            guard transport.connected else { throw HubError.authentication }
            stage = "operation"
            queueBatches: while true {
                let batch = try readPendingBatch(); var committed = false
                for next in batch {
                    guard let current = try store.pendingMetadata(next.id) else { continue }
                    // 生きた同IDの内容はenqueueが固定します。取消後に再追加された行は新しい順序で読み直します。
                    guard current.sequence == next.sequence else { continue queueBatches }
                    // 未承認の健康送信は端末に保持し、独立した食事/筋トレの同期を妨げません。
                    if next.operation.requiresHealthContract, try !store.canSendHealth(next.operation) { continue }
                    guard current.state == .queued, forceQueued || current.retryAt <= now else { break queueBatches }
                    // 古いAPIへのP4送信を止め、差分取得で対応状況を確認します。
                    if next.operation.requiresHydrationContract, try store.hydrationContract != 1 {break queueBatches}
                    if next.operation.requiresPlanningContract, try store.planningContract != 1 { break queueBatches }
                    if next.operation.requiresFoodContract, try store.foodContract != 1 { break queueBatches }
                    if next.operation.requiresHealthContract, try store.healthContract != 1 { break queueBatches }
                    do {
                        // 既存の操作IDと内容を照合し、未保存の場合だけ確定する。
                        try store.markAttempted(next.id)
                        let receipt: Receipt
                        let token = timing.begin(.operationResolve)
                        do { defer { timing.end(token, items: 1) }; receipt = try await transport.resolve(next.operation); try receipt.validate(for: next.operation) }
                        if receipt.status == "committed" {
                            try timing.measure(.operationCommit, items: 1) { try store.finish(receipt, operation: next.operation) }
                            committed = true; continue
                        }
                        let code = receipt.error_code ?? "INVALID_RESPONSE"
                        if receipt.retryable && ["BUSY", "STORAGE_UNAVAILABLE"].contains(code) { throw HubError.remote(code) }
                        let kind: PendingState = ["REVISION_CONFLICT", "CONFLICT"].contains(code) ? .conflict : .invalid
                        try store.deferOperation(next.id, state: kind, message: "要確認：\(code)", retryAt: now); break queueBatches
                    } catch {
                        let auth = error as? HubError == .authentication || error as? HubError == .accountChanged
                        let invalid = [.invalidResponse, .invalidOperation, .configuration].contains(error as? HubError)
                        let kind: PendingState = auth ? .authentication : invalid ? .invalid : .queued
                        let delay = min(300, 5 * pow(2, Double(min(current.attempts, 6))))
                        try store.deferOperation(next.id, state: kind, message: auth ? "Googleへ再接続してください" : invalid ? "取得結果が不正です・要確認" : "通信を再試行します", retryAt: now.addingTimeInterval(delay))
                        throw error
                    }
                }
                // receipt由来の取消やawait中の新規操作は次のsnapshotで順序どおり処理します。
                if !committed { break }
            }
            // ページを取得する間に正本が変わった場合、cursorは前回の成功ページから再開する。
            var snapshot: Int?; var deltaRetries = 0
            for _ in 0..<100 {
                let query = HubQuery(generation: try store.generation, after: try store.cursor, limit: 100, snapshot: snapshot)
                stage = snapshot == nil ? "intake_and_delta" : "delta"
                let page = try await fetchDelta(query, firstPage: snapshot == nil, date: date, retries: &deltaRetries)
                stage = "apply_delta"
                try timing.measure(.deltaApply, items: page.changes.count) { try store.apply(page) }; snapshot = page.snapshot_revision
                if !page.has_more { message = try readPendingBatch().isEmpty ? "同期しました" : "確定値を更新しました・送信待ちがあります"; return }
            }
            message = "取得を続けます。確認をもう一度押してください。"
        } catch {
            lastFailureCode = syncFailureCode(error); lastFailureStage = stage
            message = (error as? LocalizedError)?.errorDescription ?? "通信できませんでした。端末の記録と送信待ちは保持しています。"
        }
    }
    private func readPendingBatch() throws -> [Pending] {
        let token = timing.begin(.queueRead); var count = 0
        defer { timing.end(token, items: count) }
        let pending = try store.pending(); count = pending.count; return pending
    }
    private func fetchDelta(_ query: HubQuery, firstPage: Bool, date: String, retries: inout Int) async throws -> Delta {
        while true {
            do {
                let token = timing.begin(.deltaFetch); defer { timing.end(token) }
                return try await (firstPage ? transport.syncDelta(query, date: date) : transport.delta(query))
            }
            catch {
                let busy = error as? HubError == .remote("BUSY")
                let interrupted = (error as? URLError)?.code == .networkConnectionLost
                guard retries < 2, busy || interrupted else { throw error }
                retries += 1
                // 差分の取得だけを再試行。受付は同IDで照合され、送信待ちの操作は再送しない。
                // BUSYでは先行するGAS実行が終わる時間を空ける。認証/型/競合エラーは即停止。
                let token = timing.begin(.retryWait); defer { timing.end(token) }
                try await retryWait(busy ? 20_000_000_000 : 1_000_000_000)
            }
        }
    }
}

// 診断ログには既知のコードだけを保存し、サーバーの本文やURLは残さない。
func syncFailureCode(_ error: Error) -> String {
    if let error = error as? HubError {
        switch error {
        case .invalidResponse: return "INVALID_RESPONSE"
        case .invalidOperation: return "INVALID_OPERATION"
        case .accountChanged: return "ACCOUNT_CHANGED"
        case .configuration: return "CONFIGURATION"
        case .authentication: return "AUTHENTICATION"
        case .remote(let code):
            let allowed = ["BUSY", "STORAGE_UNAVAILABLE", "SNAPSHOT_CHANGED", "CURSOR_EXPIRED", "EXECUTION_PENDING", "HTTP_429", "HTTP_500", "HTTP_502", "HTTP_503", "HTTP_504"]
            if allowed.contains(code) { return code }
            if code == "オフライン試験" { return "OFFLINE_TEST" }
            if code == "応答消失の試験" { return "RESPONSE_LOST_TEST" }
            return "REMOTE_OTHER"
        }
    }
    if let error = error as? URLError { return "NETWORK_\(error.code.rawValue)" }
    return "UNEXPECTED_ERROR"
}
