import Foundation
public let hubEnvironment = "PHH_PRODUCTION"
public enum HubError: Error, Equatable, LocalizedError {
    case invalidResponse, invalidOperation, accountChanged, configuration, authentication, remote(String)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "取得内容を確認できません。前回の確定値を保持しています。"
        case .invalidOperation: "入力内容を確認してください。"
        case .accountChanged: "保存先のアカウントが異なります。保管用アカウントで接続してください。"
        case .configuration: "接続設定を確認してください。"
        case .authentication: "Googleへの再接続が必要です。送信待ちは端末に保持しています。"
        case .remote(let code): "同期できませんでした（\(code)）。送信待ちは端末に保持しています。"
        }
    }
}
public enum Cell: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { let v = try c.decode(Double.self); guard v.isFinite else { throw HubError.invalidResponse }; self = .number(v) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .string(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .number(let v): try c.encode(v) }
    }
    public var text: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
}
public struct SyntheticMeal: Codable, Equatable, Sendable {
    public var local_date: String; public var slot = "間食"; public var name = "記録テスト"
    public var quantity: Double; public var unit = "個"; public var source = "本人"
    public var kcal: Double; public var protein_g: Double; public var fat_g: Double = 0; public var carbohydrate_g: Double
    public init(date: String, quantity: Double = 1) { local_date = date; self.quantity = quantity; kcal = 100 * quantity; protein_g = 10 * quantity; carbohydrate_g = 15 * quantity }
}
public struct HubOperation: Codable, Equatable, Identifiable, Sendable {
    public var schema_version = 1; public var environment = hubEnvironment; public var synthetic = true
    public var approval_state = "confirmed"
    public var operation_id: String; public var entity_id: String; public var action: String
    public var expected_revision: Int; public var payload: SyntheticMeal?
    public var hydration: HydrationRecord?
    public var requiresHydrationContract: Bool { hydration != nil }
    public var health: HealthCloudDelta?
    public var requiresHealthContract: Bool { health != nil }
    public var planning: PlanningMutation?
    public var requiresPlanningContract: Bool { planning != nil }
    public var foodMeal: FoodMeal?
    public var foodVersion: FoodVersion?; public var foodCategory: FoodCategory?; public var foodPreset: FoodPreset?
    public var requiresFoodContract: Bool { foodMeal != nil || foodVersion != nil || foodCategory != nil || foodPreset != nil }
    public var trainingCycle: TrainingCyclePayload?
    public var trainingSession: TrainingSessionPayload?
    public var id: String { operation_id }
    public init(action: String, entityID: String = UUID().uuidString.lowercased(), revision: Int = 0, meal: SyntheticMeal? = nil) {
        operation_id = UUID().uuidString.lowercased(); entity_id = entityID; self.action = action; expected_revision = revision; payload = meal
    }
    enum CodingKeys: String, CodingKey { case schema_version, environment, synthetic, approval_state, operation_id, entity_id, action, expected_revision, payload }
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        schema_version=try c.decode(Int.self,forKey:.schema_version);environment=try c.decode(String.self,forKey:.environment);synthetic=try c.decode(Bool.self,forKey:.synthetic);approval_state=try c.decode(String.self,forKey:.approval_state)
        operation_id=try c.decode(String.self,forKey:.operation_id);entity_id=try c.decode(String.self,forKey:.entity_id);action=try c.decode(String.self,forKey:.action);expected_revision=try c.decode(Int.self,forKey:.expected_revision)
        if ["confirm_water","update_water","remove_water"].contains(action) { hydration=try c.decode(HydrationRecord.self,forKey:.payload) }
        else if action == "save_health_delta" { health = try c.decode(HealthCloudDelta.self, forKey: .payload) }
        else if PlanningMutation.actions.contains(action) { planning=try c.decode(PlanningMutation.self,forKey:.payload) }
        else if ["confirm_food_meal","update_food_meal","remove_food_meal"].contains(action) { foodMeal=try c.decode(FoodMeal.self,forKey:.payload) }
        else if action=="save_food_version" { foodVersion=try c.decode(FoodVersion.self,forKey:.payload) }
        else if action=="save_food_category" { foodCategory=try c.decode(FoodCategory.self,forKey:.payload) }
        else if action=="save_food_preset" { foodPreset=try c.decode(FoodPreset.self,forKey:.payload) }
        else if action=="register_training_cycle" { trainingCycle=try c.decode(TrainingCyclePayload.self,forKey:.payload) }
        else if action=="update_training_session" { trainingSession=try c.decode(TrainingSessionPayload.self,forKey:.payload) }
        else { payload=try c.decodeIfPresent(SyntheticMeal.self,forKey:.payload) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema_version, forKey: .schema_version); try c.encode(environment, forKey: .environment); try c.encode(synthetic, forKey: .synthetic)
        try c.encode(approval_state, forKey: .approval_state); try c.encode(operation_id, forKey: .operation_id); try c.encode(entity_id, forKey: .entity_id)
        try c.encode(action, forKey: .action); try c.encode(expected_revision, forKey: .expected_revision)
        if let hydration { try c.encode(hydration,forKey:.payload) } else if let health { try c.encode(health,forKey:.payload) } else if let planning { try c.encode(planning,forKey:.payload) } else if let foodMeal { try c.encode(foodMeal,forKey:.payload) } else if let foodVersion { try c.encode(foodVersion,forKey:.payload) } else if let foodCategory { try c.encode(foodCategory,forKey:.payload) } else if let foodPreset { try c.encode(foodPreset,forKey:.payload) } else if let trainingCycle { try c.encode(trainingCycle,forKey:.payload) } else if let trainingSession { try c.encode(trainingSession,forKey:.payload) } else if let payload { try c.encode(payload, forKey: .payload) } else { try c.encodeNil(forKey: .payload) }
    }
    public func validate() throws {
        guard schema_version == 1, environment == hubEnvironment, (synthetic || action == "save_health_delta" || ["confirm_water","update_water","remove_water","confirm_food_meal","update_food_meal","remove_food_meal","save_food_version","save_food_category","save_food_preset"].contains(action)), UUID(uuidString: id) != nil, UUID(uuidString: entity_id) != nil,
              approval_state == "confirmed", expected_revision >= 0, expected_revision < 9007199254740991, (action == "save_health_delta" || PlanningMutation.actions.contains(action) || ["confirm_water","update_water","remove_water","confirm_meal", "update_meal", "remove_meal", "register_training_cycle", "update_training_session", "confirm_food_meal", "update_food_meal", "remove_food_meal", "save_food_version", "save_food_category", "save_food_preset"].contains(action)),
              (action == "save_health_delta" || PlanningMutation.actions.contains(action) || action.hasPrefix("save_food_") || (["confirm_water","confirm_meal","register_training_cycle","confirm_food_meal"].contains(action) ? expected_revision == 0 : expected_revision > 0)) else { throw HubError.invalidOperation }
        if ["confirm_water","update_water","remove_water"].contains(action) {
            guard let hydration, payload == nil, health == nil, planning == nil, foodMeal == nil, foodVersion == nil, foodCategory == nil, foodPreset == nil, trainingCycle == nil, trainingSession == nil else { throw HubError.invalidOperation }
            do { try hydration.validate() } catch { throw HubError.invalidOperation }
            guard hydration.id == entity_id, hydration.revision == expected_revision+1, action == (expected_revision==0 ? "confirm_water" : hydration.removed ? "remove_water" : "update_water"), expected_revision>0 || !hydration.removed else { throw HubError.invalidOperation };return
        }
        guard hydration == nil else {throw HubError.invalidOperation}
        if action == "save_health_delta" { try validateHealth(); return }
        guard health == nil else { throw HubError.invalidOperation }
        if PlanningMutation.actions.contains(action) { try validatePlanning();return }
        guard planning == nil else { throw HubError.invalidOperation }
        if action.hasPrefix("save_food_") { try validateFoodCatalog();return }
        guard foodVersion == nil,foodCategory == nil,foodPreset == nil else { throw HubError.invalidOperation }
        if ["confirm_food_meal","update_food_meal","remove_food_meal"].contains(action) {
            guard let foodMeal,payload == nil,trainingCycle == nil,trainingSession == nil else { throw HubError.invalidOperation }
            do { let op=try FoodPendingOperation(id:id,expectedRevision:expected_revision,meal:foodMeal);let wire=try FoodWireOperation(op,environment:environment,synthetic:synthetic);try wire.validate();guard wire.action==action,wire.entity_id==entity_id else { throw HubError.invalidOperation } } catch { throw HubError.invalidOperation };return
        }
        guard foodMeal == nil else { throw HubError.invalidOperation }
        if action == "register_training_cycle" { guard let trainingCycle,payload == nil,trainingSession == nil else { throw HubError.invalidOperation };try trainingCycle.validate();return }
        if action == "update_training_session" { guard let trainingSession,payload == nil,trainingCycle == nil else { throw HubError.invalidOperation };try trainingSession.validate();return }
        guard trainingCycle == nil,trainingSession == nil else { throw HubError.invalidOperation }
        if action == "remove_meal" { guard payload == nil else { throw HubError.invalidOperation }; return }
        guard let p = payload, Schema.validDate(p.local_date), [1.0, 2.0].contains(p.quantity), p == SyntheticMeal(date: p.local_date, quantity: p.quantity) else { throw HubError.invalidOperation }
    }
}
public struct Receipt: Codable, Sendable {
    public var environment: String?; public var operation_id: String; public var status: String
    public var error_code: String?; public var entity_ids: [String]?; public var revisions: [Int]?; public var retryable: Bool
    public func validate(for op: HubOperation) throws {
        guard operation_id == op.id, ["committed", "rejected", "not_found"].contains(status), status == "not_found" || environment == hubEnvironment else { throw HubError.invalidResponse }
        if status == "committed" { guard entity_ids == [op.entity_id], revisions == [op.expected_revision + 1], !retryable, error_code == nil else { throw HubError.invalidResponse } }
    }
}
public struct Change: Codable, Sendable {
    public var change_number: Int; public var table_name: String; public var entity_id: String
    public var revision: Int; public var indexed_revision: Int; public var removed: Bool
    public var local_date: String?
    public init(change_number:Int,table_name:String,entity_id:String,revision:Int,indexed_revision:Int,removed:Bool,local_date:String?) {
        self.change_number=change_number;self.table_name=table_name;self.entity_id=entity_id;self.revision=revision;self.indexed_revision=indexed_revision;self.removed=removed;self.local_date=local_date
    }
}
public struct ChangedRow: Codable, Sendable {
    public var change: Change; public var record: [String: Cell]
    public init(change:Change,record:[String:Cell]) {self.change=change;self.record=record}
}
public struct Delta: Codable, Sendable {
    public var schema_version: Int; public var environment: String; public var generation: Int
    public var hydration_contract: Int? = nil
    public var health_contract: Int? = nil
    public var planning_contract: Int? = nil
    public var food_contract: Int? = nil
    public var training_contract: Int? = nil
    public var snapshot_revision: Int; public var changes: [ChangedRow]; public var next_cursor: Int; public var has_more: Bool
    public init(schema_version:Int,environment:String,generation:Int,hydration_contract:Int?=nil,health_contract:Int?=nil,planning_contract:Int?=nil,food_contract:Int?=nil,training_contract:Int?=nil,snapshot_revision:Int,changes:[ChangedRow],next_cursor:Int,has_more:Bool) {
        self.schema_version=schema_version;self.environment=environment;self.generation=generation;self.hydration_contract=hydration_contract;self.health_contract=health_contract;self.planning_contract=planning_contract;self.food_contract=food_contract;self.training_contract=training_contract;self.snapshot_revision=snapshot_revision;self.changes=changes;self.next_cursor=next_cursor;self.has_more=has_more
    }
}
public struct HubQuery: Codable, Sendable {
    public var schema_version = 1; public var environment = hubEnvironment; public var synthetic = true
    public var operation_id: String?; public var local_date: String?; public var generation: Int?; public var after: Int?; public var limit: Int?; public var snapshot_revision: Int?
    public init(operationID: String? = nil, date: String? = nil, generation: Int? = nil, after: Int? = nil, limit: Int? = nil, snapshot: Int? = nil) {
        operation_id = operationID; local_date = date; self.generation = generation; self.after = after; self.limit = limit; snapshot_revision = snapshot
    }
}
public struct LocalRow: Identifiable, Equatable, Sendable {
    public var table: String; public var values: [String: Cell]
    public var entityID: String { values["id"]?.text ?? "" }; public var id: String { table + ":" + entityID }
    public var revision: Int { guard let n = values["revision"]?.number, n.isFinite, n >= 1, n <= 9007199254740991, n.rounded() == n else { return 0 }; return Int(n) }
    public var active: Bool { values["status"]?.text != "removed" }
}
public enum PendingState: String, Sendable { case queued, authentication, invalid, conflict }
public struct Pending: Identifiable, Sendable {
    public var operation: HubOperation; public var state: PendingState; public var message: String
    public var retryAt: Date; public var attempts: Int; public var sequence: Int
    public var id: String { operation.id }
}
struct Schema: Decodable {
    struct Table: Decodable { var columns: [Column] }; struct Column: Decodable { var name: String; var type: String; var nullable: Bool }
    var tables: [String: Table]
    static let bundled = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "schema", withExtension: "json")!))
    static let trainingP3 = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "training-p3-schema", withExtension: "json")!))
    static let foodP4 = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "food-p4-schema", withExtension: "json")!))
    static let planningP5 = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "planning-p5-schema", withExtension: "json")!))
    static let healthP6 = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "health-p6-schema", withExtension: "json")!))
    static let hydrationP8 = try! JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "hydration-p8-schema", withExtension: "json")!))
    static func validDate(_ s: String) -> Bool {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return s.count == 10 && f.date(from: s).map { f.string(from: $0) == s } == true
    }
    static let syncTables: Set<String> = Set(PlanningRows.tables).union(["Meals", "MealItems", "IntakeNutrients", "TrainingSessions", "TrainingSets", "TrainingNotes", "DailySummary", "TrainingCycles", "TrainingPlanSlots", "FoodVersions", "FoodNutrients", "Categories", "Presets", "PresetItems", "HealthBatches", "HealthArchives", "HealthDaily", "WaterIntakes"])
    static func sameRecordDuringP3Upgrade(table:String,old:[String:Cell],new:[String:Cell]) -> Bool {
        let schemas=[bundled,trainingP3,foodP4,planningP5,healthP6,hydrationP8]
        guard schemas.contains(where: { $0.tables[table].map { Set(old.keys)==Set($0.columns.map(\.name)) } ?? false }),
              schemas.contains(where: { $0.tables[table].map { Set(new.keys)==Set($0.columns.map(\.name)) } ?? false }),
              old.allSatisfy({new[$0.key]==$0.value}),Set(old.keys).isSubset(of:Set(new.keys)) else { return false }
        return new.filter {old[$0.key]==nil}.values.allSatisfy {$0 == .null}
    }
    static func validate(_ row: LocalRow) throws {
        guard syncTables.contains(row.table), row.revision > 0 else { throw HubError.invalidResponse }
        let candidates = [bundled.tables[row.table], trainingP3.tables[row.table], foodP4.tables[row.table], planningP5.tables[row.table], healthP6.tables[row.table],hydrationP8.tables[row.table]].compactMap { $0 }
        guard let spec = candidates.first(where: { Set(row.values.keys) == Set($0.columns.map(\.name)) }) else { throw HubError.invalidResponse }
        if row.table == "DailySummary" { guard validDate(row.entityID) else { throw HubError.invalidResponse } }
        else if row.table == "TrainingPlanSlots" { guard let cycle=row.values["cycle_id"]?.text, UUID(uuidString:cycle) != nil, let n=row.values["number"]?.number, (1...9).contains(n), n.rounded()==n, row.entityID == cycle+"#"+String(Int(n)) else { throw HubError.invalidResponse } }
        else { guard UUID(uuidString:row.entityID) != nil else { throw HubError.invalidResponse } }
        for col in spec.columns {
            switch row.values[col.name]! {
            case .null: guard col.nullable else { throw HubError.invalidResponse }
            case .string(let v): guard col.type == "string", v.count < 45000 else { throw HubError.invalidResponse }
            case .bool: guard col.type == "boolean" else { throw HubError.invalidResponse }
            case .number(let v): guard v.isFinite, col.type == "number" || col.type == "integer" && v.rounded() == v && abs(v) <= 9007199254740991 else { throw HubError.invalidResponse }
            }
        }
        if let status = row.values["status"]?.text { guard ["active", "removed"].contains(status) else { throw HubError.invalidResponse } }
        if let date = row.values["local_date"]?.text { guard validDate(date) else { throw HubError.invalidResponse } }
        for key in ["quantity", "weight_kg", "reps", "value", "kcal", "protein_g", "fat_g", "carbohydrate_g", "meal_count", "training_set_count", "kcal_unknown", "protein_unknown", "fat_unknown", "carbohydrate_unknown"] {
            if let n = row.values[key]?.number { guard n >= 0 else { throw HubError.invalidResponse } }
        }
    }
}
