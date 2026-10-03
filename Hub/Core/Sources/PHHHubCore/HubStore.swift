import Foundation
import CoreData

/// 記録・送信待ち・cursorは別の行。差分とcursorは同じCore Data saveで確定します。
@MainActor public final class HubStore {
    internal var healthCommitCheck: (() throws -> Void)?
    // 合成試験はHealthLocalの明示的な取得回数だけを計測し、UUIDや本文を出力しません。
    internal var healthLocalFetchCheck: ((_ keyCount: Int) -> Void)?
    internal var pendingMetadataFetchCheck: (() -> Void)?
    private let container: NSPersistentContainer
    private var decodedOutbox: [NSManagedObjectID: (payload: Data, operation: HubOperation)] = [:]
    private var context: NSManagedObjectContext { container.viewContext }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    internal static func makeModel(includeHealth: Bool) -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        func entity(_ name: String, _ attributes: [(String, NSAttributeType)]) -> NSEntityDescription {
            let e = NSEntityDescription(); e.name = name; e.managedObjectClassName = "NSManagedObject"
            e.properties = attributes.map { name, type in let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = false; return a }
            e.uniquenessConstraints = [["key"]]; return e
        }
        let base = [entity("Record", [("key", .stringAttributeType), ("table", .stringAttributeType), ("date", .stringAttributeType), ("payload", .binaryDataAttributeType), ("revision", .integer64AttributeType)]),
                          entity("Outbox", [("key", .stringAttributeType), ("payload", .binaryDataAttributeType), ("state", .stringAttributeType), ("message", .stringAttributeType), ("retry", .doubleAttributeType), ("attempts", .integer64AttributeType), ("sequence", .integer64AttributeType)]),
                          entity("Meta", [("key", .stringAttributeType), ("value", .stringAttributeType)])]
        model.entities = base + (includeHealth ? [
                          entity("HealthLocal", [("key", .stringAttributeType), ("metric", .stringAttributeType), ("date", .stringAttributeType), ("start", .doubleAttributeType), ("payload", .binaryDataAttributeType), ("removed", .booleanAttributeType)]),
                          entity("HealthStatistic", [("key", .stringAttributeType), ("metric", .stringAttributeType), ("date", .stringAttributeType), ("payload", .binaryDataAttributeType)])] : [])
        return model
    }
    private static func upgradeHealthStoreIfNeeded(_ url: URL, model: NSManagedObjectModel) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
        if model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { return }
        let legacy = makeModel(includeHealth: false)
        guard legacy.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) else { throw HubError.configuration }
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: legacy, destinationModel: model)
        let migrated = url.deletingLastPathComponent().appendingPathComponent("health-migration-" + UUID().uuidString + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: migrated.path + suffix) } }
        let manager = NSMigrationManager(sourceModel: legacy, destinationModel: model)
        try manager.migrateStore(from: url, sourceType: NSSQLiteStoreType, options: nil, with: mapping, toDestinationURL: migrated, destinationType: NSSQLiteStoreType, destinationOptions: nil)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.replacePersistentStore(at: url, destinationOptions: nil, withPersistentStoreFrom: migrated, sourceOptions: nil, ofType: NSSQLiteStoreType)
    }
    public init(url: URL? = nil, owner: String) throws {
        let model = Self.makeModel(includeHealth: true)
        container = NSPersistentContainer(name: "PersonalHealthHub", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        if let url {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryURL = directory; var resource = URLResourceValues(); resource.isExcludedFromBackup = true; try directoryURL.setResourceValues(resource)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject, forKey: NSPersistentStoreFileProtectionKey)
            #endif
            try Self.upgradeHealthStoreIfNeeded(url, model: model)
            description.url = url; description.type = NSSQLiteStoreType
        } else { description.type = NSInMemoryStoreType }
        description.shouldMigrateStoreAutomatically = true; description.shouldInferMappingModelAutomatically = true
        description.shouldAddStoreAsynchronously = false; container.persistentStoreDescriptions = [description]
        var failure: Error?; container.loadPersistentStores { _, error in failure = error }; if let failure { throw failure }
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        if let existing = try meta("owner") { guard existing == owner.lowercased(), try meta("environment") == hubEnvironment else { throw HubError.accountChanged } }
        else { try atomic { try setMeta("owner", owner.lowercased()); try setMeta("environment", hubEnvironment); try setMeta("generation", "1"); try setMeta("cursor", "0"); try setMeta("sequence", "0") } }
    }
    private func find(_ entity: String, _ key: String) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity); request.predicate = NSPredicate(format: "key == %@", key); request.fetchLimit = 2
        if entity == "HealthLocal" { healthLocalFetchCheck?(1) }
        let rows = try context.fetch(request); guard rows.count <= 1 else { throw HubError.invalidResponse }; return rows.first
    }
    private func object(_ entity: String, _ key: String) throws -> NSManagedObject {
        if let row = try find(entity, key) { return row }
        let row = NSEntityDescription.insertNewObject(forEntityName: entity, into: context); row.setValue(key, forKey: "key"); return row
    }
    private func atomic(_ work: () throws -> Void) throws { do { try work(); try context.save() } catch { context.rollback(); throw error } }
    private func meta(_ key: String) throws -> String? { try find("Meta", key)?.value(forKey: "value") as? String }
    private func setMeta(_ key: String, _ value: String) throws { try object("Meta", key).setValue(value, forKey: "value") }
    public var catalogEntryContract: Int { get throws { Int(try meta("catalog_entry_contract") ?? "0") ?? 0 } }
    public var hydrationContract: Int { get throws { Int(try meta("hydration_contract") ?? "0") ?? 0 } }
    public var healthContract: Int { get throws { Int(try meta("health_contract") ?? "0") ?? 0 } }
    public var planningContract: Int { get throws { Int(try meta("planning_contract") ?? "0") ?? 0 } }
    public var foodContract: Int { get throws { Int(try meta("food_contract") ?? "0") ?? 0 } }
    // 保存成功の受領後、正本の再取得が遅れても端末表示と次の編集を保持します。
    // Recordには混ぜず、同じ版以上の正本を取得したら一時コピーを除きます。
    public func acknowledgedFoodMeals(confirmed:[FoodMeal]) throws -> [FoodMeal] {
        let request=NSFetchRequest<NSManagedObject>(entityName:"Meta")
        request.predicate=NSPredicate(format:"key BEGINSWITH %@","food_ack:")
        var meals:[FoodMeal]=[],obsolete:[NSManagedObject]=[]
        for row in try context.fetch(request) {
            guard let key=row.value(forKey:"key") as? String,let text=row.value(forKey:"value") as? String else {throw HubError.invalidResponse}
            let meal=try JSONDecoder().decode(FoodMeal.self,from:Data(text.utf8));try meal.validate()
            guard key=="food_ack:"+meal.id else {throw HubError.invalidResponse}
            if confirmed.contains(where:{$0.id==meal.id && $0.revision>=meal.revision}) {obsolete.append(row)}
            else {meals.append(meal)}
        }
        if !obsolete.isEmpty {try atomic {for row in obsolete {context.delete(row)}}}
        return meals.sorted {$0.id<$1.id}
    }
    public var trainingContract: Int { get throws { Int(try meta("training_contract") ?? "0") ?? 0 } }
    public var cursor: Int { get throws { guard let value = try meta("cursor"), let n = Int(value), n >= 0 else { throw HubError.invalidResponse }; return n } }
    public var generation: Int { get throws { guard let value = try meta("generation"), let n = Int(value), n > 0 else { throw HubError.invalidResponse }; return n } }
    public func rows(table: String? = nil, date: String? = nil) throws -> [LocalRow] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
        var predicates: [NSPredicate] = []
        if let table { predicates.append(NSPredicate(format: "table == %@", table)) }
        if let date { predicates.append(NSPredicate(format: "date == %@", date)) }
        if !predicates.isEmpty { request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates) }
        return try context.fetch(request).map { row in
            guard let table = row.value(forKey: "table") as? String, let bytes = row.value(forKey: "payload") as? Data else { throw HubError.invalidResponse }
            return LocalRow(table: table, values: try JSONDecoder().decode([String: Cell].self, from: bytes))
        }.sorted { $0.id < $1.id }
    }
    public func pending() throws -> [Pending] {
        let r = NSFetchRequest<NSManagedObject>(entityName: "Outbox"); r.sortDescriptors = [.init(key: "sequence", ascending: true)]
        var current: [NSManagedObjectID: (payload: Data, operation: HubOperation)] = [:]
        let pending = try context.fetch(r).map { row in
            guard let data = row.value(forKey: "payload") as? Data, let raw = row.value(forKey: "state") as? String, let state = PendingState(rawValue: raw), let message = row.value(forKey: "message") as? String else { throw HubError.invalidResponse }
            // Scan every live row before sending, including malformed later rows. Reuse only an exact payload match.
            let operation: HubOperation
            if let cached = decodedOutbox[row.objectID], cached.payload == data { operation = cached.operation }
            else { operation = try JSONDecoder().decode(HubOperation.self, from: data) }
            current[row.objectID] = (data, operation)
            return Pending(operation: operation, state: state, message: message, retryAt: Date(timeIntervalSince1970: row.value(forKey: "retry") as? Double ?? 0), attempts: row.value(forKey: "attempts") as? Int ?? 0, sequence: row.value(forKey: "sequence") as? Int ?? 0)
        }
        decodedOutbox = current // Each successful full read prunes the cache to rows still present in the Outbox.
        return pending
    }
    internal struct PendingMetadata: Sendable {
        let state: PendingState; let retryAt: Date; let attempts: Int; let sequence: Int
    }
    /// 送信直前の状態だけを取得します。大きなHealth payloadは取得・decodeしません。
    internal func pendingMetadata(_ id: String) throws -> PendingMetadata? {
        let request = NSFetchRequest<NSDictionary>(entityName: "Outbox")
        request.predicate = NSPredicate(format: "key == %@", id); request.fetchLimit = 2
        request.resultType = .dictionaryResultType; request.propertiesToFetch = ["state", "retry", "attempts", "sequence"]
        pendingMetadataFetchCheck?()
        let rows = try context.fetch(request); guard rows.count <= 1 else { throw HubError.invalidResponse }
        guard let row = rows.first else { return nil }
        guard let raw = row["state"] as? String, let state = PendingState(rawValue: raw) else { throw HubError.invalidResponse }
        return PendingMetadata(state: state, retryAt: Date(timeIntervalSince1970: row["retry"] as? Double ?? 0),
            attempts: row["attempts"] as? Int ?? 0, sequence: row["sequence"] as? Int ?? 0)
    }
    public func enqueue(_ food: FoodWireOperation) throws {
        guard try foodContract == 1 else { throw HubError.configuration }
        try enqueue(food.hubOperation())
    }
    private func insertQueued(_ operation:HubOperation) throws {
        let payload=try encoder.encode(operation)
        if let row=try find("Outbox",operation.id) { guard row.value(forKey:"payload") as? Data==payload else { throw HubError.invalidOperation };return }
        let sequence=(Int(try meta("sequence") ?? "0") ?? 0)+1,row=try object("Outbox",operation.id)
        for (key,value) in ["payload":payload,"state":PendingState.queued.rawValue,"message":"端末に保存・同期待ち","retry":0.0,"attempts":0,"sequence":sequence] as [String:Any] {row.setValue(value,forKey:key)}
        try setMeta("sequence",String(sequence))
        if operation.foodMeal != nil {try setMeta("food_origin:"+operation.entity_id,operation.id+"|"+(operation.synthetic ? "1":"0"))}
    }
    public func enqueue(_ operation:HubOperation) throws { try enqueueBatch([operation]) }
    public func enqueueBatch(_ operations:[HubOperation]) throws {
        for op in operations { if op.requiresCatalogEntryContract {guard try catalogEntryContract==1 else {throw HubError.configuration}};if op.requiresHydrationContract { guard try hydrationContract==1 else {throw HubError.configuration} };if op.requiresFoodContract { guard try foodContract==1 else {throw HubError.configuration} };try op.validate() }
        try atomic { for op in operations { try insertQueued(op) } }
    }
    internal func cancelUnsentPlanning(_ id: String) throws {
        guard let p = try pending().first(where: { $0.id == id }), p.operation.requiresPlanningContract,
          p.attempts == 0, p.state == .queued else { throw HubError.invalidOperation }
        try atomic { if let row = try find("Outbox", id) { context.delete(row) } }
    }
    public func markAttempted(_ id:String) throws {
        try atomic { guard let row=try find("Outbox",id) else {throw HubError.invalidOperation};row.setValue((row.value(forKey:"attempts") as? Int ?? 0)+1,forKey:"attempts") }
    }
    public func foodUndoRequested(_ id:String) throws -> Bool { try meta("food_undo:"+id)=="1" || meta("food_restore:"+id) != nil }
    public func foodUndoReplacement(_ id: String) throws -> FoodMeal? {
        try foodUndoRestoration(id)?.foodMeal
    }
    public func foodUndoRestoration(_ id: String) throws -> HubOperation? {
        guard let text = try meta("food_restore:"+id) else { return nil }
        let operation = try JSONDecoder().decode(HubOperation.self, from: Data(text.utf8)); try operation.validate()
        guard operation.foodMeal != nil else { throw HubError.invalidResponse }; return operation
    }
    public func hydrationUndoRestoration(_ id: String) throws -> HubOperation? {
        guard let text=try meta("water_restore:"+id) else {return nil}
        let op=try JSONDecoder().decode(HubOperation.self,from:Data(text.utf8));try op.validate()
        guard op.hydration != nil else {throw HubError.invalidResponse};return op
    }
    public func undoHydrationChange(_ change: HydrationUndoChange, at: Date = .now, synthetic: Bool = false) throws {
        guard at <= change.expiresAt else {throw HubError.invalidOperation}
        let op=try change.restoration(current:change.after).operation(id:change.undoID,synthetic:synthetic),outbox=try pending()
        if outbox.contains(where:{$0.id==change.undoID}) {return}
        if let original=outbox.first(where:{$0.id==change.operationID}) {
            guard original.operation.hydration == change.after,original.state == .queued || original.state == .authentication else {throw HubError.invalidOperation}
            try atomic {
                if original.attempts==0 && original.state == .queued {if let row=try find("Outbox",original.id){context.delete(row)}}
                else {try setMeta("water_restore:"+original.id,String(decoding:encoder.encode(op),as:UTF8.self))}
            }
        } else {
            guard outbox.allSatisfy({$0.operation.entity_id != change.after.id}),let current=try HydrationRows.records(rows(table:"WaterIntakes")).first(where:{$0.id==change.after.id}) else {throw HubError.invalidOperation}
            _=try change.restoration(current:current);try enqueue(op)
        }
    }
    private func foodOriginalSynthetic(entityID: String, operationID: String, fallback: Bool) throws -> Bool {
        guard let text = try meta("food_origin:"+entityID) else {return fallback}
        let parts = text.split(separator:"|",omittingEmptySubsequences:false)
        guard parts.count == 2, UUID(uuidString:String(parts[0])) != nil, ["0","1"].contains(String(parts[1])) else {throw HubError.invalidResponse}
        return String(parts[0]) == operationID ? parts[1] == "1" : fallback
    }
    private func currentFoodMeal(_ id: String) throws -> FoodMeal? {
        let confirmed = try FoodSnapshotReader.meals(["Meals", "MealItems", "IntakeNutrients"].flatMap { try rows(table: $0) })
        return (confirmed + (try acknowledgedFoodMeals(confirmed: confirmed))).filter { $0.id == id }.max { $0.revision < $1.revision }
    }
    public func undoFoodChange(_ change: FoodUndoChange, at: Date = .now, synthetic: Bool = true) throws {
        try change.validate(); guard change.available(at: at) else { throw FoodFailure.invalidValue }
        let outbox = try pending()
        if outbox.contains(where: { $0.id == change.undoID }) { return }
        let original = outbox.first(where: { $0.id == change.operationID })
        let marker = try original?.operation.synthetic ?? foodOriginalSynthetic(entityID:change.after.id,operationID:change.operationID,fallback:synthetic)
        let restoration = try change.restoration(current: change.after)
        let op = try FoodWireOperation(.init(id: change.undoID, expectedRevision: change.after.revision, meal: restoration), environment: hubEnvironment, synthetic: marker).hubOperation()
        if let original {
            guard original.operation.foodMeal == change.after,
                !outbox.contains(where:{$0.operation.entity_id==change.after.id && $0.sequence>original.sequence}),
                original.state == .queued || original.state == .authentication else { throw FoodFailure.pendingEdit }
            try atomic {
                if original.attempts == 0 && original.state == .queued { if let row = try find("Outbox", original.id) { context.delete(row) } }
                else { try setMeta("food_restore:"+original.id, String(decoding: encoder.encode(op), as: UTF8.self)) }
            }
        } else {
            guard outbox.allSatisfy({ $0.operation.entity_id != change.after.id }) else { throw FoodFailure.pendingEdit }
            guard let current = try currentFoodMeal(change.after.id) else { throw FoodFailure.missingReference }
            _ = try change.restoration(current: current)
            try enqueue(op)
        }
    }
    public func undoFoodAddition(_ operation:HubOperation) throws {
        try operation.validate();guard let meal=operation.foodMeal,operation.expected_revision==0 else {throw HubError.invalidOperation}
        let outbox = try pending()
        if let pending=outbox.first(where:{$0.id==operation.id}) {
            guard !outbox.contains(where:{$0.operation.entity_id==meal.id && $0.sequence>pending.sequence && $0.operation.expected_revision>=meal.revision}),
                pending.state == .queued || pending.state == .authentication else {throw FoodFailure.pendingEdit}
            try atomic {
                if pending.attempts==0 && pending.state == .queued { if let row=try find("Outbox",pending.id) {context.delete(row)} }
                else {try setMeta("food_undo:"+operation.id,"1")}
            }
        } else {
            guard outbox.allSatisfy({$0.operation.entity_id != meal.id}) else {throw FoodFailure.pendingEdit}
            let current=try currentFoodMeal(meal.id) ?? meal
            let marker = try foodOriginalSynthetic(entityID:meal.id,operationID:operation.id,fallback:operation.synthetic)
            if !current.removed {try enqueue(FoodWireOperation(.init(expectedRevision:current.revision,meal:current.edited(remove:true)),environment:hubEnvironment,synthetic:marker).hubOperation())}
        }
    }
    public func finish(_ receipt:Receipt,operation:HubOperation) throws {
        try receipt.validate(for:operation);guard receipt.status=="committed" else {throw HubError.invalidResponse}
        try atomic {
            guard let row=try find("Outbox",operation.id) else {return}
            if let meal=operation.foodMeal {
                try setMeta("food_origin:"+operation.entity_id,operation.id+"|"+(operation.synthetic ? "1":"0"))
                let key="food_ack:"+meal.id
                let previous=try meta(key).map {try JSONDecoder().decode(FoodMeal.self,from:Data($0.utf8))}
                try previous?.validate()
                if (previous?.revision ?? 0)<meal.revision {try setMeta(key,String(decoding:encoder.encode(meal),as:UTF8.self))}
            }
            if let restored=try hydrationUndoRestoration(operation.id) {
                guard restored.entity_id==operation.entity_id,restored.expected_revision==operation.hydration?.revision else {throw HubError.invalidOperation}
                try insertQueued(restored)
                if let marker=try find("Meta","water_restore:"+operation.id){context.delete(marker)}
            } else if let text = try meta("food_restore:"+operation.id) {
                let restored = try JSONDecoder().decode(HubOperation.self, from: Data(text.utf8)); try restored.validate()
                guard restored.entity_id == operation.entity_id, restored.expected_revision == operation.foodMeal?.revision, restored.synthetic == operation.synthetic else { throw HubError.invalidOperation }
                try insertQueued(restored)
                if let marker = try find("Meta", "food_restore:"+operation.id) { context.delete(marker) }
            } else if try meta("food_undo:"+operation.id)=="1",let meal=operation.foodMeal,!meal.removed {
                try insertQueued(FoodWireOperation(.init(expectedRevision:meal.revision,meal:meal.edited(remove:true)),environment:hubEnvironment,synthetic:operation.synthetic).hubOperation())
                if let marker=try find("Meta","food_undo:"+operation.id) {context.delete(marker)}
            }
            context.delete(row)
        }
    }
    public func deferOperation(_ id: String, state: PendingState, message: String, retryAt: Date) throws {
        try atomic {
            guard let row = try find("Outbox", id) else { throw HubError.invalidOperation }
            row.setValue(state.rawValue, forKey: "state"); row.setValue(message, forKey: "message"); row.setValue(retryAt.timeIntervalSince1970, forKey: "retry")
            row.setValue((row.value(forKey: "attempts") as? Int ?? 0) + 1, forKey: "attempts")
        }
    }
    public func discardRejected(_ id: String) throws {
        guard let pending = try pending().first(where: { $0.id == id }), [.conflict, .invalid].contains(pending.state) else { throw HubError.invalidOperation }
        try atomic { if let row = try find("Outbox", id) { context.delete(row) } }
    }
    /// 要確認の操作を、同じ操作IDのまま送信待ちへ戻す（一時的な障害で止まった場合の「もう一度送る」）。
    public func requeueRejected(_ id: String) throws {
        guard let pending = try pending().first(where: { $0.id == id }), [.conflict, .invalid].contains(pending.state) else { throw HubError.invalidOperation }
        try atomic { let row = try object("Outbox", id); row.setValue(PendingState.queued.rawValue, forKey: "state"); row.setValue(0.0, forKey: "retry"); row.setValue("もう一度送ります", forKey: "message") }
    }
    public func resumeAuthentication() throws {
        try atomic {
            for item in try pending() where item.state == .authentication {
                let row = try object("Outbox", item.id); row.setValue(PendingState.queued.rawValue, forKey: "state"); row.setValue(0.0, forKey: "retry"); row.setValue("再接続済み・同期待ち", forKey: "message")
            }
        }
    }
    public func apply(_ page: Delta) throws {
        let start = try cursor
        guard page.catalog_entry_contract == nil || page.catalog_entry_contract == 1 else {throw HubError.invalidResponse}
        guard page.hydration_contract == nil || page.hydration_contract == 1 else {throw HubError.invalidResponse}
        guard page.health_contract == nil || page.health_contract == 1 else { throw HubError.invalidResponse }
        guard page.planning_contract == nil || page.planning_contract == 1 else { throw HubError.invalidResponse }
        guard page.food_contract == nil || page.food_contract == 1 else { throw HubError.invalidResponse }
        guard page.training_contract == nil || page.training_contract == 1 else { throw HubError.invalidResponse }
        guard page.environment == hubEnvironment, page.schema_version == 1, page.generation == (try generation), page.snapshot_revision >= start,
              page.changes.count <= 500, page.next_cursor <= page.snapshot_revision, page.has_more == (page.next_cursor < page.snapshot_revision),
              page.next_cursor == start + page.changes.count else { throw HubError.invalidResponse }
        for (i, item) in page.changes.enumerated() {
            let c = item.change, row = LocalRow(table: c.table_name, values: item.record)
            guard c.change_number == start + i + 1, c.entity_id == row.entityID, c.revision == row.revision, c.indexed_revision > 0, c.indexed_revision <= c.revision,
                  c.removed == !row.active, c.local_date == nil || Schema.validDate(c.local_date!) else { throw HubError.invalidResponse }
            try Schema.validate(row)
            if row.table=="CatalogEntries" {guard page.catalog_entry_contract==1,c.local_date==nil else {throw HubError.invalidResponse};_ = try FoodCatalogEntryRows.entries([row])}
            if row.table=="WaterIntakes" {guard page.hydration_contract==1,c.local_date==row.values["local_date"]?.text else {throw HubError.invalidResponse};_ = try HydrationRows.records([row])}
            if PlanningRows.tables.contains(row.table) { guard page.planning_contract == 1 else { throw HubError.invalidResponse } }
            if Set(item.record.keys) == Set(Schema.foodP4.tables[row.table]?.columns.map(\.name) ?? []),
               Schema.trainingP3.tables[row.table]?.columns.map(\.name) != Schema.foodP4.tables[row.table]?.columns.map(\.name) {
                guard page.food_contract == 1 else { throw HubError.invalidResponse }
            }
        }
        try atomic {
            for item in page.changes {
                let c = item.change, key = c.table_name + ":" + c.entity_id, payload = try encoder.encode(item.record)
                let row = try object("Record", key), old = row.value(forKey: "revision") as? Int ?? 0
                if old == c.revision { guard let oldPayload=row.value(forKey:"payload") as? Data else { throw HubError.invalidResponse };let oldValues=try JSONDecoder().decode([String:Cell].self,from:oldPayload);guard oldPayload==payload || Schema.sameRecordDuringP3Upgrade(table:c.table_name,old:oldValues,new:item.record) else { throw HubError.invalidResponse };if oldPayload==payload {continue} }
                if old > c.revision { continue }
                row.setValue(c.table_name, forKey: "table"); row.setValue(c.local_date ?? "", forKey: "date"); row.setValue(payload, forKey: "payload"); row.setValue(c.revision, forKey: "revision")
            }
            try setMeta("catalog_entry_contract",String(page.catalog_entry_contract ?? 0));try setMeta("hydration_contract",String(page.hydration_contract ?? 0));try setMeta("health_contract", String(page.health_contract ?? 0)); try setMeta("planning_contract", String(page.planning_contract ?? 0)); try setMeta("cursor", String(page.next_cursor)); try setMeta("training_contract",String(page.training_contract ?? 0)); try setMeta("food_contract",String(page.food_contract ?? 0))
        }
    }
}

public struct HealthStoredPage: Sendable {
    public let records: [HealthLocalRecord], totalCount: Int, hasMore: Bool
}
@MainActor extension HubStore {
    private func healthIdentity(_ scope: HealthQueryScope) -> String {
        "health_identity:\(scope.deviceID):\(scope.metric.rawValue):\(scope.phase.rawValue):\(scope.conditionVersion)"
    }
    public func registerHealthScope(_ scope: HealthQueryScope) throws {
        try scope.validate()
        if let existing = try healthProgress(scope.id) { guard existing.scope == scope else { throw HealthFailure.invalidScope }; return }
        guard try meta(healthIdentity(scope)) == nil else { throw HealthFailure.invalidScope }
        let progress = HealthImportProgress(scope: scope, anchor: nil, complete: false, receivedAt: nil, readState: .noDataOrNotAuthorized)
        try atomic {
            try setMeta("health_scope:" + scope.id, String(decoding: encoder.encode(progress), as: UTF8.self))
            try setMeta(healthIdentity(scope), scope.id)
        }
    }
    public func healthProgress(_ id: String) throws -> HealthImportProgress? {
        guard let value = try meta("health_scope:" + id.lowercased()) else { return nil }
        let progress = try JSONDecoder().decode(HealthImportProgress.self, from: Data(value.utf8)); try progress.scope.validate()
        return progress
    }
    public func healthScopes() throws -> [HealthImportProgress] {
        let r = NSFetchRequest<NSManagedObject>(entityName: "Meta"); r.predicate = NSPredicate(format: "key BEGINSWITH %@", "health_scope:")
        return try context.fetch(r).map { row in
            guard let value = row.value(forKey: "value") as? String else { throw HubError.invalidResponse }
            let p = try JSONDecoder().decode(HealthImportProgress.self, from: Data(value.utf8)); try p.scope.validate(); return p
        }.sorted { $0.scope.id < $1.scope.id }
    }
    public func setHealthUploadPolicy(_ policy: HealthUploadPolicy) throws {
        let validated = try HealthUploadPolicy(allowedMetrics: policy.allowedMetrics, from: policy.from, authorizedAt: policy.authorizedAt)
        try atomic { try setMeta("health_upload_policy", String(decoding: encoder.encode(validated), as: UTF8.self)) }
    }
    public func healthUploadPolicy() throws -> HealthUploadPolicy {
        guard let value = try meta("health_upload_policy") else { return try HealthUploadPolicy() }
        let p = try JSONDecoder().decode(HealthUploadPolicy.self, from: Data(value.utf8))
        return try HealthUploadPolicy(allowedMetrics: p.allowedMetrics, from: p.from, authorizedAt: p.authorizedAt)
    }
    public func canSendHealth(_ op: HubOperation) throws -> Bool {
        guard let health = op.health, try healthContract == 1 else { return false }
        try op.validate(); if op.synthetic { return true }; return try healthUploadPolicy().allows(health)
    }
    public func healthRecord(_ id: String) throws -> HealthLocalRecord? {
        guard let row = try find("HealthLocal", id.lowercased()) else { return nil }
        return try decodeHealthRecord(row, id: id)
    }
    private func decodeHealthRecord(_ row: NSManagedObject, id: String) throws -> HealthLocalRecord? {
        guard UUID(uuidString: id) != nil, let data = row.value(forKey: "payload") as? Data else { throw HubError.invalidResponse }
        let value = try JSONDecoder().decode(HealthLocalRecord.self, from: data)
        if let sample = value.sample { try sample.validate(); guard sample.id == id.lowercased() else { throw HubError.invalidResponse } }
        guard value.sample != nil || value.removed else { throw HubError.invalidResponse }; return value
    }
    private func healthLocalObjects(_ ids: Set<String>) throws -> [String: NSManagedObject] {
        guard !ids.isEmpty else { return [:] }
        let keys = Set(ids.map { $0.lowercased() })
        let request = NSFetchRequest<NSManagedObject>(entityName: "HealthLocal")
        request.predicate = NSPredicate(format: "key IN %@", Array(keys))
        request.fetchLimit = keys.count + 1; request.returnsObjectsAsFaults = false
        healthLocalFetchCheck?(keys.count)
        var objects: [String: NSManagedObject] = [:]
        for row in try context.fetch(request) {
            guard let key = row.value(forKey: "key") as? String, keys.contains(key), objects[key] == nil else { throw HubError.invalidResponse }
            objects[key] = row
        }
        return objects
    }
    /// 該当ページのUUIDを一括取得し、同じオブジェクトを一回のCore Data saveで確定します。
    @discardableResult public func ingestHealth(_ page: HealthImportPage, synthetic: Bool) throws -> HealthCloudDelta? {
        guard page.added.count + page.deletedIDs.count <= 500,
            page.added.allSatisfy({ UUID(uuidString: $0.id) != nil }),
            page.deletedIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw HealthFailure.invalidValue }
        guard let progress = try healthProgress(page.scopeID) else { throw HealthFailure.invalidScope }
        let ids = Set(page.added.map(\.id) + page.deletedIDs), objects = try healthLocalObjects(ids)
        var records: [String: HealthLocalRecord] = [:]
        for id in ids {
            if let row = objects[id.lowercased()], let record = try decodeHealthRecord(row, id: id) { records[id] = record }
        }
        var receipts: [String: String] = [:]
        if let hash = try meta("health_receipt:" + page.id) { receipts[page.id] = hash }
        var ledger = try HealthLocalLedger(records: records, progress: progress, receipts: receipts)
        guard let delta = try ledger.apply(page), var next = ledger.scopes[page.scopeID], let hash = ledger.receipts[page.id] else { return nil }
        let op = try HubOperation(health: delta, synthetic: synthetic)
        try atomic {
            for (id, record) in ledger.records {
                let row: NSManagedObject
                if let existing = objects[id.lowercased()] { row = existing }
                else { row = NSEntityDescription.insertNewObject(forEntityName: "HealthLocal", into: context); row.setValue(id, forKey: "key") }
                row.setValue(progress.scope.metric.rawValue, forKey: "metric"); row.setValue(record.sample.map { HealthDates.local($0.metric == .sleepAnalysis ? $0.end : $0.start) } ?? "", forKey: "date")
                row.setValue(record.sample?.start.timeIntervalSince1970 ?? 0, forKey: "start"); row.setValue(record.removed, forKey: "removed"); row.setValue(try encoder.encode(record), forKey: "payload")
            }
            for statistic in delta.statistics {
                let row = try object("HealthStatistic", statistic.metric.rawValue + ":" + statistic.date)
                if let oldData = row.value(forKey: "payload") as? Data {
                    let old = try JSONDecoder().decode(HealthDailyStatistics.self, from: oldData)
                    if old.measuredAt > statistic.measuredAt { continue }
                }
                row.setValue(statistic.metric.rawValue, forKey: "metric"); row.setValue(statistic.date, forKey: "date"); row.setValue(try encoder.encode(statistic), forKey: "payload")
            }
            if progress.scope.metric.isCumulative {
                for date in delta.affectedDates {
                    let dirty = HealthDirtyDay(metric: progress.scope.metric, date: date, id: UUID().uuidString.lowercased())
                    try setMeta(healthDirtyKey(dirty.metric, date), String(decoding: encoder.encode(dirty), as: UTF8.self))
                }
            }
            let count = NSFetchRequest<NSFetchRequestResult>(entityName: "HealthLocal"); count.predicate = NSPredicate(format: "metric == %@ AND removed == NO", progress.scope.metric.rawValue)
            next.readState = try context.count(for: count) > 0 ? .available : .noDataOrNotAuthorized
            try setMeta("health_scope:" + page.scopeID, String(decoding: encoder.encode(next), as: UTF8.self))
            try setMeta("health_receipt:" + page.id, hash)
            if !delta.added.isEmpty || !delta.deletedIDs.isEmpty || !delta.statistics.isEmpty { try insertQueued(op) }
            try healthCommitCheck?()
        }
        return delta
    }
    public func markHealthReadFailure(_ id: String, state: HealthReadState) throws {
        guard var progress = try healthProgress(id), [.unavailable, .temporaryFailure].contains(state) else { throw HealthFailure.invalidScope }
        progress.readState = state
        try atomic { try setMeta("health_scope:" + id, String(decoding: encoder.encode(progress), as: UTF8.self)) }
    }
    public func healthRecords(metric: HealthMetric, date: String? = nil, offset: Int = 0, limit: Int = 100, includeRemoved: Bool = false) throws -> HealthStoredPage {
        guard offset >= 0, limit > 0, limit <= 500, date == nil || Schema.validDate(date!) else { throw HealthFailure.invalidValue }
        let r = NSFetchRequest<NSManagedObject>(entityName: "HealthLocal")
        var predicates = [NSPredicate(format: "metric == %@", metric.rawValue)]
        if let date { predicates.append(NSPredicate(format: "date == %@", date)) }; if !includeRemoved { predicates.append(NSPredicate(format: "removed == NO")) }
        r.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let count = try context.count(for: r); r.fetchOffset = offset; r.fetchLimit = limit; r.sortDescriptors = [.init(key: "start", ascending: false), .init(key: "key", ascending: true)]
        let records = try context.fetch(r).map { row -> HealthLocalRecord in
            guard let id = row.value(forKey: "key") as? String,
                  let record = try decodeHealthRecord(row, id: id) else { throw HubError.invalidResponse }
            return record
        }
        return HealthStoredPage(records: records, totalCount: count, hasMore: offset + records.count < count)
    }
    public func healthStatistics(metric: HealthMetric, date: String) throws -> HealthDailyStatistics? {
        guard metric.isCumulative, Schema.validDate(date) else { throw HealthFailure.invalidValue }
        guard let row = try find("HealthStatistic", metric.rawValue + ":" + date), let data = row.value(forKey: "payload") as? Data else { return nil }
        return try JSONDecoder().decode(HealthDailyStatistics.self, from: data)
    }
    private func healthDirtyKey(_ metric: HealthMetric, _ date: String) -> String { "health_dirty:\(metric.rawValue):\(date)" }
    public var healthReadEnabled: Bool { get throws { try meta("health_read_enabled") == "true" } }
    public func setHealthReadEnabled(_ enabled: Bool) throws {
        try atomic { try setMeta("health_read_enabled", enabled ? "true" : "false") }
    }
    public func markHealthCatchUpPending(metric: HealthMetric) throws {
        let scopes = try healthScopes().filter { $0.scope.metric == metric }
        try atomic {
            for var progress in scopes {
                progress.complete = false
                try setMeta("health_scope:" + progress.scope.id, String(decoding: encoder.encode(progress), as: UTF8.self))
            }
        }
    }
    public func healthDirtyDays(metric: HealthMetric, limit: Int = 100) throws -> [HealthDirtyDay] {
        guard metric.isCumulative, limit > 0, limit <= 500 else { throw HealthFailure.invalidValue }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Meta")
        request.predicate = NSPredicate(format: "key BEGINSWITH %@", "health_dirty:\(metric.rawValue):")
        request.sortDescriptors = [.init(key: "key", ascending: true)]; request.fetchLimit = limit
        return try context.fetch(request).map { row in
            guard let value = row.value(forKey: "value") as? String else { throw HubError.invalidResponse }
            let dirty = try JSONDecoder().decode(HealthDirtyDay.self, from: Data(value.utf8))
            guard dirty.metric == metric, Schema.validDate(dirty.date), UUID(uuidString: dirty.id) != nil else { throw HubError.invalidResponse }
            return dirty
        }
    }
    /// 日次統計のみを確定し、同じdirty tokenを操作IDとして再送します。raw/anchorは変更しません。
    @discardableResult public func commitHealthStatistics(_ statistic: HealthDailyStatistics, dirty: HealthDirtyDay, synthetic: Bool) throws -> Bool {
        try statistic.validate()
        guard statistic.metric == dirty.metric, statistic.date == dirty.date, UUID(uuidString: dirty.id) != nil else { throw HealthFailure.invalidValue }
        let data = try encoder.encode(statistic), receiptKey = "health_stat_receipt:" + dirty.id
        if let previous = try meta(receiptKey) {
            guard previous == data.base64EncodedString() else { throw HealthFailure.pageIDReused }; return false
        }
        let key = healthDirtyKey(dirty.metric, dirty.date)
        guard let current = try meta(key), try JSONDecoder().decode(HealthDirtyDay.self, from: Data(current.utf8)) == dirty else { return false }
        if let old = try healthStatistics(metric: dirty.metric, date: dirty.date) {
            // 空結果は読取拒否との区別ができません。既知値を消す根拠にしません。
            if old.measuredAt > statistic.measuredAt || old.value != nil && statistic.value == nil { return false }
        }
        let delta = HealthCloudDelta(id: dirty.id, metric: dirty.metric, added: [], deletedIDs: [], affectedDates: [dirty.date], statistics: [statistic])
        let operation = try HubOperation(health: delta, synthetic: synthetic)
        try atomic {
            let row = try object("HealthStatistic", dirty.metric.rawValue + ":" + dirty.date)
            row.setValue(dirty.metric.rawValue, forKey: "metric"); row.setValue(dirty.date, forKey: "date"); row.setValue(data, forKey: "payload")
            try insertQueued(operation); try setMeta(receiptKey, data.base64EncodedString())
            if let marker = try find("Meta", key) { context.delete(marker) }
            try healthCommitCheck?()
        }
        return true
    }
}
