import Foundation
import HealthKit
import UIKit
import PHHHubCore

@MainActor final class HealthRuntime {
    private let store: HubStore
    private let client = HealthKitClient()
    private let onChanged: () -> Void
    private lazy var pipeline = HealthImportPipeline(store: store, client: client)
    private var observers: [HealthMetric: HKObserverQuery] = [:]
    private(set) var lastOutcome: HealthImportOutcome?
    init(store: HubStore, onChanged: @escaping () -> Void = {}) { self.store = store; self.onChanged = onChanged }
    /// 起動時は保存済みの明示設定とscopeだけを使い、認可UIや新scopeを作りません。
    func startIfEnabled() {
        guard (try? store.healthReadEnabled) == true, let scopes = try? store.healthScopes(), !scopes.isEmpty else { return }
        client.readingEnabled = true
        for metric in Set(scopes.map { $0.scope.metric }) where observers[metric] == nil {
            guard let type = try? HealthKitClient.type(metric) else { continue }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                let acknowledgement = HealthObserverCompletion(completion)
                Task { @MainActor in
                    guard let self else { acknowledgement.call(); return }
                    if error != nil {
                        for progress in (try? self.store.healthScopes()) ?? [] where progress.scope.metric == metric {
                            try? self.store.markHealthReadFailure(progress.scope.id, state: .temporaryFailure)
                        }
                        acknowledgement.call(); self.onChanged(); return
                    }
                    self.lastOutcome = await self.pipeline.catchUp(metric: metric, completion: { acknowledgement.call() })
                    self.onChanged()
                }
            }
            observers[metric] = query; client.healthStore.execute(query)
            Task {
                guard (try? store.healthReadEnabled) == true else { return }
                try? await client.healthStore.enableBackgroundDelivery(for: type, frequency: .immediate)
                if (try? store.healthReadEnabled) != true { try? await client.healthStore.disableBackgroundDelivery(for: type) }
            }
        }
    }
    /// まとめ確認で本人が押す認可操作にだけ接続します。scopeは呼出側で確認・登録済みである必要があります。
    func authorizeRegisteredScopes() async throws {
        let scopes = try store.healthScopes(); guard !scopes.isEmpty else { throw HealthFailure.invalidScope }
        try await client.requestReadAuthorization(metrics: Set(scopes.map { $0.scope.metric }))
        try store.setHealthReadEnabled(true); startIfEnabled(); await foregroundCatchUp()
    }
    func foregroundCatchUp(maxPages: Int = 8) async {
        guard (try? store.healthReadEnabled) == true else { return }
        startIfEnabled()
        for metric in Set(((try? store.healthScopes()) ?? []).map { $0.scope.metric }).sorted(by: { $0.rawValue < $1.rawValue }) {
            lastOutcome = await pipeline.catchUp(metric: metric, maxPages: maxPages); onChanged()
        }
    }
    func disableReading() throws {
        try store.setHealthReadEnabled(false); client.readingEnabled = false
        for (metric, query) in observers {
            pipeline.cancel(metric: metric); client.healthStore.stop(query)
            if let type = try? HealthKitClient.type(metric) { Task { try? await client.healthStore.disableBackgroundDelivery(for: type) } }
        }
        observers.removeAll()
    }
}

/// SDKの非Sendable completionを一度だけ消費します。可変状態は同じlockで保護します。
private final class HealthObserverCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: HKObserverQueryCompletionHandler?
    init(_ callback: @escaping HKObserverQueryCompletionHandler) { self.callback = callback }
    func call() {
        lock.lock(); let saved = callback; callback = nil; lock.unlock()
        saved?()
    }
}

/// HubApp.initでfactoryを渡し、UIApplicationDelegateAdaptorで接続します。
/// SwiftUIのtaskより前に、既有効設定のObserverを設置します。
@MainActor final class HealthAppDelegate: NSObject, UIApplicationDelegate {
    static var makeRuntime: (() -> HealthRuntime?)?
    private(set) var runtime: HealthRuntime?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        runtime = Self.makeRuntime?(); runtime?.startIfEnabled(); return true
    }
}
