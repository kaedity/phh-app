import Foundation
import Observation
import PHHHubCore
@MainActor @Observable final class HubModel {
    static let shared = HubModel()
    private(set) var healthRuntime: HealthRuntime?
    private(set) var healthReadPrepared = false
    private(set) var healthReadEnabled = false
    let google: GoogleTransport; let chatGPT: ChatGPTSession
    let previewOnly: Bool
    private var store: HubStore?; private var engine: SyncEngine?
    private var foodSyncRequested=false
    private(set) var busy = false; private(set) var message = "準備しています"
    private(set) var trainingCycles:[TrainingCycleReference] = []
    private(set) var trainingWriteEnabled=false
    private(set) var foodWriteEnabled=false
    private(set) var healthScreen: HealthScreenModel?
    private(set) var autoSleepDeliveries: [AutoSleepDelivery] = []
    private(set) var planningScreen: PlanningScreenModel?
    private(set) var foodScreen:FoodScreenModel?
    private(set) var trainingSnapshot: TrainingSnapshot = .empty
    private(set) var rows: [LocalRow] = []; private(set) var pending: [Pending] = []
    var date: String = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Tokyo"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
    init() { previewOnly = false; google = GoogleTransport(); chatGPT = ChatGPTSession(); configureStore() }
    #if DEBUG
    init(previewStore: HubStore, empty: Bool, syncing: Bool, failure: Bool) throws {
        previewOnly = true; google = GoogleTransport(offline: true); chatGPT = ChatGPTSession(offline: true)
        store = previewStore; date = "2026-10-02"
        foodScreen = FoodScreenModel(store: try FoodLocalStore(initial: FoodLocalState(catalog: empty ? .init() : FoodPreviewData.catalog, confirmed: empty ? [] : FoodPreviewData.meals)))
        planningScreen = try PlanningScreenModel(hub: previewStore, onSaved: {})
        healthScreen = try HealthScreenModel(store: previewStore, date: date)
        trainingSnapshot = empty ? .empty : TrainingPreviewData.snapshot
        trainingCycles = empty ? [] : [TrainingPreviewData.cycle]
        foodWriteEnabled = true; pending = try previewStore.pending(); busy = syncing
        message = failure ? "取得内容を確認できません。前回の確定値を保持しています。" : syncing ? "同期しています（合成表示）" : "架空データ · 認証と通信なし"
    }
    #endif
    private func configureStore() {
        guard store == nil else { return }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Hub", isDirectory: true)
            let store = try HubStore(url: directory.appendingPathComponent("hub.sqlite"), owner: google.ownerEmail)
            self.store = store; engine = SyncEngine(store: store, transport: google);
            healthScreen = try HealthScreenModel(store:store,date:date)
            healthReadPrepared = healthConfiguration()["HealthReadApproved"] as? Bool == true
            healthReadEnabled = try store.healthReadEnabled
            healthRuntime = HealthRuntime(store:store,onChanged:{[weak self] in
                guard let self else { return }
                do { try self.reloadHealth() } catch { self.message = "健康データの前回値を保持しています" }
                if self.google.connected, (try? self.pending.contains(where: { pending in guard pending.state == .queued, pending.operation.requiresHealthContract else { return false }; return try store.canSendHealth(pending.operation) })) == true { self.requestFoodSync() }
            })
            planningScreen=try PlanningScreenModel(hub:store,onSaved:{[weak self] in self?.requestFoodSync() })
            foodScreen=try FoodScreenModel(store:FoodHubStore(hub:store),onSaved:{[weak self] in self?.requestFoodSync() });try reload(); message = "架空データの接続確認を行えます"
        } catch { message = error.localizedDescription }
    }
    private func requestFoodSync() { if busy {foodSyncRequested=true} else {Task {await synchronize()} } }
    func start() async {
        guard !previewOnly else { return }
        configureStore(); refreshCurrentDay(); healthRuntime?.startIfEnabled()
        await google.restore(); if google.connected { await synchronize() }
        await catchUpHealth()
    }
    private func healthConfiguration() -> [String:Any] {
        guard let url=Bundle.main.url(forResource:"Connection",withExtension:"plist"), let data=try? Data(contentsOf:url), let values=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else { return [:] }
        return values
    }
    func connectHealth() async {
        guard healthReadPrepared, let store, let healthRuntime else { return }
        do {
            let key="phh.health.deviceID", device=UserDefaults.standard.string(forKey:key) ?? UUID().uuidString.lowercased(); UserDefaults.standard.set(device,forKey:key)
            let existing=try store.healthScopes()
            let lower=existing.filter { $0.scope.deviceID == device && $0.scope.phase == .recent }.map(\.scope.lowerBound).min() ?? HealthDates.calendar.date(byAdding:.day,value:-30,to:Date())!
            for metric in HealthMetric.allCases where !existing.contains(where: { $0.scope.deviceID == device && $0.scope.metric == metric && $0.scope.phase == .recent }) {
                try store.registerHealthScope(HealthQueryScope(deviceID:device,metric:metric,phase:.recent,lowerBound:lower))
            }
            // 外部保存の承認は読取許可と分け、設定が明示された時だけ反映します。
            if healthConfiguration()["HealthUploadApproved"] as? Bool == true {
                let scopes=try store.healthScopes().filter { $0.scope.deviceID == device && $0.scope.phase == .recent }
                guard let from=scopes.map({HealthDates.local($0.scope.lowerBound)}).max() else { throw HealthFailure.invalidScope }
                try store.setHealthUploadPolicy(HealthUploadPolicy(allowedMetrics:Set(HealthMetric.allCases),from:from,authorizedAt:Date()))
            }
            try await healthRuntime.authorizeRegisteredScopes(); healthReadEnabled=try store.healthReadEnabled; try reload()
        } catch { message="健康データの接続を完了できませんでした。前回値と送信待ちは保持しています。" }
    }
    func catchUpHealth() async {
        guard !previewOnly else { return }
        configureStore(); refreshCurrentDay(); await healthRuntime?.foregroundCatchUp(); do { try reloadHealth() } catch { message="健康データの前回値を保持しています" }
    }
    private func refreshCurrentDay() {
        let today = HealthDates.local(Date())
        guard date != today else { return }; date = today
        do { try reload() } catch { message = "前回の記録を保持しています。再取得してください。" }
    }
    private func reloadHealth() throws {
        guard let store else { return }
        let enabled = try store.healthReadEnabled, outbox = try store.pending()
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Hub/AutoSleep", isDirectory: true)
        let deliveries = try AutoSleepInbox(url: directory.appendingPathComponent("intake.json")).deliveries()
        try healthScreen?.refresh(date: date)
        healthReadEnabled = enabled; pending = outbox; autoSleepDeliveries = deliveries
    }
    func loginGoogle() async {
        guard !previewOnly else { return }
        guard !busy else { return }; busy = true
        do { try await google.signIn(); try store?.resumeAuthentication(); message = google.authMessage } catch { message = error.localizedDescription }
        busy = false; if google.connected { await synchronize() }
    }
    func synchronize(forceQueued: Bool = false) async {
        guard !previewOnly else { return }
        guard !busy, let engine else { return }; busy = true; defer { busy = false;if foodSyncRequested { foodSyncRequested=false;Task {await synchronize()} } }
        let started = Date()
        google.timing.reset()
        await engine.synchronize(date: date, forceQueued: forceQueued); message = engine.message
        let reloadStarted = ProcessInfo.processInfo.systemUptime
        do { try reload() } catch { message = error.localizedDescription }
        let reloadSeconds = ProcessInfo.processInfo.systemUptime - reloadStarted
        let elapsed = Date().timeIntervalSince(started)
        if engine.message == "同期しました" { message += String(format: "（%.1f秒）", elapsed) }
        recordSyncTiming(started: started, elapsed: elapsed, succeeded: engine.message == "同期しました", reloadSeconds: reloadSeconds)
    }
    private func recordSyncTiming(started: Date, elapsed: Double, succeeded: Bool, reloadSeconds: Double) {
        // P2の架空データ試験用。認証情報・記録本文・メールアドレスを保存しない。
        struct Timing: Codable { let started: Date; let elapsed_seconds: Double; let succeeded: Bool; let pending_count: Int; let pending_ids: [String]?; let pending_states: [String]?; let simulated_failure: String?; let failure_code: String?; let failure_stage: String?; let reload_seconds: Double?; let engine_stage_metrics: [SyncTimingMetric]?; let request_stage_metrics: [SyncTimingMetric]? }
        guard let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        let path = root.appendingPathComponent("Hub/sync-timing.json")
        var entries = (try? Data(contentsOf: path)).flatMap { try? JSONDecoder().decode([Timing].self, from: $0) } ?? []
        entries.append(Timing(started: started, elapsed_seconds: elapsed, succeeded: succeeded, pending_count: pending.count, pending_ids: pending.map(\.id), pending_states: pending.map { $0.state.rawValue }, simulated_failure: message.contains("応答消失の試験") ? "response_lost_test" : message.contains("オフライン試験") ? "offline_test" : nil, failure_code: engine?.lastFailureCode, failure_stage: engine?.lastFailureStage, reload_seconds: reloadSeconds, engine_stage_metrics: engine?.timing.metrics, request_stage_metrics: google.timing.metrics))
        guard let data = try? JSONEncoder().encode(Array(entries.suffix(50))) else { return }
        try? data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func makeMeal() async { await queue(HubOperation(action: "confirm_meal", meal: SyntheticMeal(date: date))) }
    func changeMeal(_ meal: LocalRow, quantity: Double) async { await queue(HubOperation(action: "update_meal", entityID: meal.entityID, revision: meal.revision, meal: SyntheticMeal(date: date, quantity: quantity))) }
    func removeMeal(_ meal: LocalRow) async { await queue(HubOperation(action: "remove_meal", entityID: meal.entityID, revision: meal.revision)) }
    #if DEBUG
    func testLostResponse() async {
        guard !busy else { return }; google.debugLoseNextReceipt = true; await makeMeal()
    }
    func testInvalidDelta() async {
        guard !busy else { return }; google.debugCorruptNextDelta = true; await synchronize()
    }
    func testAuthenticationLoss() async {
        guard !busy else { return }; google.debugExpireNextCall = true; await makeMeal()
    }
    func testConflict() async {
        guard !busy, let meal = meals.first else { return }
        await queue(HubOperation(action: "update_meal", entityID: meal.entityID, revision: meal.revision + 1, meal: SyntheticMeal(date: date, quantity: 2)))
    }
    func testInvalidInput() async {
        guard !busy else { return }; var meal = SyntheticMeal(date: date); meal.kcal = -1
        await queue(HubOperation(action: "confirm_meal", meal: meal))
    }
    func discardRejected(_ id: String) {
        guard !busy else { return }
        do { try store?.discardRejected(id); try reload(); message = "要確認の試験操作を破棄しました。確定記録は保持しています。" }
        catch { message = error.localizedDescription }
    }
    #endif
    private func queue(_ operation: HubOperation) async {
        guard !busy, let store else { return }
        do { try store.enqueue(operation); try reload(); message = "端末に保存しました・同期待ち"; await synchronize() } catch { message = error.localizedDescription }
    }
    func registerTrainingCycle(_ reference:TrainingCycleReference) async -> String {
        guard !busy,trainingWriteEnabled else { return busy ? "同期しています。処理が終わってから保存してください。":"筋トレの保存接続は準備中です。参照は画面内だけです。" }
        await queue(HubOperation(cycle:reference));return message
    }
    func updateTrainingSession(_ session:TrainingSession,state:TrainingLifecycle,cycle:TrainingCycleReference?,slot:TrainingPlanSlot?) async -> String {
        guard !busy,trainingWriteEnabled,let row=try? store?.rows(table:"TrainingSessions").first(where:{$0.entityID==session.id}) else { return busy ? "同期しています。処理が終わってから保存してください。":"保存接続またはセッションを確認してください。" }
        await queue(HubOperation(sessionID:session.id,revision:row.revision,state:state,cycle:cycle,slot:slot));return message
    }
    func reload() throws {
        guard let store else { return }
        let trainingRows=try ["TrainingSessions","TrainingSets","TrainingNotes"].flatMap { try store.rows(table:$0) }
        let snapshot=try TrainingSnapshot(rows:trainingRows),currentRows=try store.rows(date:date),outbox=try store.pending()
        let cycles=try TrainingCycleReference.read(rows:["TrainingCycles","TrainingPlanSlots"].flatMap { try store.rows(table:$0) }),enabled=try store.trainingContract==1
        healthReadEnabled = try store.healthReadEnabled
        try healthScreen?.refresh(date:date)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Hub/AutoSleep", isDirectory: true)
        autoSleepDeliveries = try AutoSleepInbox(url:directory.appendingPathComponent("intake.json")).deliveries()
        try planningScreen?.refresh();try foodScreen?.refresh();let foodEnabled=try store.foodContract==1
        // 取得途中のCycle等が不正なら、画面の前回値をまとめて保持します。
        rows=currentRows;pending=outbox;trainingSnapshot=snapshot;trainingCycles=cycles;trainingWriteEnabled=enabled;foodWriteEnabled=foodEnabled
    }
    var meals: [LocalRow] { rows.filter { $0.table == "Meals" && $0.active } }
    var training: [LocalRow] { rows.filter { ["TrainingSets", "TrainingNotes"].contains($0.table) && $0.active } }
    var summary: LocalRow? { rows.first { $0.table == "DailySummary" } }
    func kcal(_ meal: LocalRow) -> Double? {
        let itemIDs = Set(rows.filter { $0.table == "MealItems" && $0.values["meal_id"]?.text == meal.entityID && $0.active }.map(\.entityID))
        let values = rows.filter { $0.table == "IntakeNutrients" && $0.active && itemIDs.contains($0.values["item_id"]?.text ?? "") && $0.values["nutrient_id"]?.text == "kcal" }
        guard !values.isEmpty, values.allSatisfy({ $0.values["value"]?.number != nil }) else { return nil }
        return values.reduce(0) { $0 + ($1.values["value"]?.number ?? 0) }
    }
}
