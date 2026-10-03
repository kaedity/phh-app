import Foundation
public struct TrainingCyclePayload: Codable, Equatable, Sendable {
    public struct Slot: Codable, Equatable, Sendable { public let number:Int, label:String, kind:String }
    public let name:String, source_path:String, source_sha256:String
    public let slots:[Slot]
    public init(_ reference:TrainingCycleReference) { name=reference.name;source_path=reference.sourcePath;source_sha256=reference.sha256;slots=reference.slots.map { Slot(number:$0.number,label:$0.label,kind:$0.kind.rawValue) } }
    public func validate() throws {
        guard !name.isEmpty,name.count<=200,!source_path.isEmpty,source_path.count<=2000,source_sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,slots.map(\.number)==Array(1...9),slots.allSatisfy({ !$0.label.isEmpty && $0.label.count<=200 && TrainingKind(rawValue:$0.kind) != nil }) else { throw HubError.invalidOperation }
    }
}
public struct TrainingSessionPayload: Codable, Equatable, Sendable {
    public let lifecycle_state:String
    public let cycle_id:String?, plan_slot_id:String?
    public init(state:TrainingLifecycle,cycle:TrainingCycleReference?=nil,slot:TrainingPlanSlot?=nil) { lifecycle_state=state.rawValue;cycle_id=cycle?.id;plan_slot_id=slot?.id }
    enum CodingKeys:String,CodingKey { case lifecycle_state,cycle_id,plan_slot_id }
    public func encode(to encoder:Encoder) throws { var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(lifecycle_state,forKey:.lifecycle_state);if let cycle_id { try c.encode(cycle_id,forKey:.cycle_id) } else { try c.encodeNil(forKey:.cycle_id) };if let plan_slot_id { try c.encode(plan_slot_id,forKey:.plan_slot_id) } else { try c.encodeNil(forKey:.plan_slot_id) } }
    public func validate() throws { guard TrainingLifecycle(rawValue:lifecycle_state) != nil,cycle_id.map({UUID(uuidString:$0) != nil}) ?? true,plan_slot_id == nil || (cycle_id != nil && (1...9).contains(where: { plan_slot_id == cycle_id!+"#"+String($0) })) else { throw HubError.invalidOperation } }
}
public extension HubOperation {
    init(cycle:TrainingCycleReference) { self.init(action:"register_training_cycle",entityID:cycle.id);trainingCycle=TrainingCyclePayload(cycle) }
    init(sessionID:String,revision:Int,state:TrainingLifecycle,cycle:TrainingCycleReference?=nil,slot:TrainingPlanSlot?=nil) { self.init(action:"update_training_session",entityID:sessionID,revision:revision);trainingSession=TrainingSessionPayload(state:state,cycle:cycle,slot:slot) }
}
public extension TrainingCycleReference {
    static func read(rows:[LocalRow]) throws -> [TrainingCycleReference] {
        let active=rows.filter(\.active),cycles=active.filter {$0.table=="TrainingCycles"},slots=active.filter {$0.table=="TrainingPlanSlots"}
        guard Set(cycles.map(\.entityID)).count==cycles.count,Set(slots.map(\.entityID)).count==slots.count,slots.allSatisfy({ slot in cycles.contains {$0.entityID==slot.values["cycle_id"]?.text} }) else { throw HubError.invalidResponse }
        return try cycles.map { row in
            try Schema.validate(row)
            let children=try slots.filter {$0.values["cycle_id"]?.text==row.entityID}.map { slot -> TrainingPlanSlot in
                try Schema.validate(slot);guard let n=slot.values["number"]?.number,let label=slot.values["label"]?.text,let kind=slot.values["kind"]?.text.flatMap(TrainingKind.init(rawValue:)) else { throw HubError.invalidResponse }
                return TrainingPlanSlot(id:slot.entityID,number:Int(n),label:label,kind:kind)
            }.sorted {$0.number<$1.number}
            guard children.map(\.number)==Array(1...9),let name=row.values["name"]?.text,let path=row.values["source_path"]?.text,let hash=row.values["source_sha256"]?.text else { throw HubError.invalidResponse }
            let reference=TrainingCycleReference(id:row.entityID,name:name,sourcePath:path,sha256:hash,slots:children)
            try TrainingCyclePayload(reference).validate();return reference
        }.sorted {$0.name<$1.name}
    }
}
