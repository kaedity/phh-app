import Foundation

public extension HydrationRecord {
    func edited(date: String? = nil, amountML: Double? = nil, removed: Bool? = nil) throws -> Self {
        try .init(id: id, date: date ?? self.date, revision: revision+1, amountML: amountML ?? self.amountML, removed: removed ?? self.removed)
    }
    func operation(id operationID: String = UUID().uuidString.lowercased(), synthetic: Bool = false) throws -> HubOperation {
        try validate()
        var op = HubOperation(action: revision == 1 ? "confirm_water" : removed ? "remove_water" : "update_water", entityID: id, revision: revision-1)
        op.operation_id=operationID;op.synthetic=synthetic;op.hydration=self;try op.validate();return op
    }
}
public enum HydrationRows {
    public static func records(_ rows: [LocalRow]) throws -> [HydrationRecord] {
        try rows.filter { $0.table == "WaterIntakes" }.map { row in
            try Schema.validate(row)
            guard let date=row.values["local_date"]?.text,let ml=row.values["amount_ml"]?.number,
                row.values["time_zone"]?.text == "Asia/Tokyo",let op=row.values["last_operation_id"]?.text,UUID(uuidString:op) != nil else { throw HubError.invalidResponse }
            do { return try .init(id:row.entityID,date:date,revision:row.revision,amountML:ml,removed:!row.active) }
            catch { throw HubError.invalidResponse }
        }
    }
}
public struct HydrationUndoChange: Identifiable, Sendable {
    public let operationID: String, undoID: String, before: HydrationRecord?, after: HydrationRecord, expiresAt: Date
    public var id: String { operationID }
    public init(operationID: String, before: HydrationRecord?, after: HydrationRecord, at: Date = .now) {
        self.operationID=operationID;self.before=before;self.after=after;self.expiresAt=at.addingTimeInterval(5);self.undoID=UUID().uuidString.lowercased()
    }
    public func restoration(current: HydrationRecord) throws -> HydrationRecord {
        try after.validate();try before?.validate()
        guard current == after, UUID(uuidString:operationID) != nil, UUID(uuidString:undoID) != nil,
          before.map({ $0.id==after.id && $0.revision+1==after.revision }) ?? (after.revision==1 && !after.removed) else {throw HubError.invalidOperation}
        return try after.edited(date:before?.date,amountML:before?.amountML,removed:before?.removed ?? true)
    }
}
@MainActor public extension HubStore {
    func hydrationSnapshot() throws -> [HydrationRecord] {
        var records=Dictionary(uniqueKeysWithValues:try HydrationRows.records(rows(table:"WaterIntakes")).map {($0.id,$0)})
        for p in try pending() {
            guard let water=p.operation.hydration,p.state == .queued || p.state == .authentication else {continue}
            if let restored=try hydrationUndoRestoration(p.id)?.hydration {records[water.id]=restored}
            else if records[water.id].map({$0.revision < water.revision}) ?? true {records[water.id]=water}
        }
        return records.values.sorted {$0.id < $1.id}
    }
}
