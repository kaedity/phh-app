import Foundation

public enum GoalFailure:Error,LocalizedError {
  case invalidValue,missingBase,revisionConflict
  public var errorDescription:String? {switch self {case .invalidValue:"目標の値と適用日を確認してください。";case .missingBase:"基準が未設定の項目は調整できません。";case .revisionConflict:"記録の変更があります。現在の内容を確認してください。"}}
}
public struct GoalValues:Codable,Equatable,Sendable {
  public let kcal:Double?,protein:Double?,fat:Double?,carbohydrate:Double?
  public init(kcal:Double?=nil,protein:Double?=nil,fat:Double?=nil,carbohydrate:Double?=nil) throws {
    self.kcal=kcal;self.protein=protein;self.fat=fat;self.carbohydrate=carbohydrate;try validate()
  }
  public func validate() throws {guard [kcal,protein,fat,carbohydrate].allSatisfy({$0.map {$0.isFinite && $0>=0 && $0<=100_000} ?? true}) else {throw GoalFailure.invalidValue}}
  public func adding(_ delta:GoalDelta) throws -> GoalValues {
    try delta.validate()
    func value(_ base:Double?,_ change:Double) throws -> Double? {if let base {return base+change};guard change==0 else {throw GoalFailure.missingBase};return nil}
    return try .init(kcal:value(kcal,delta.kcal),protein:value(protein,delta.protein),fat:value(fat,delta.fat),carbohydrate:value(carbohydrate,delta.carbohydrate))
  }
}
public struct GoalDelta:Codable,Equatable,Sendable {
  public let kcal:Double,protein:Double,fat:Double,carbohydrate:Double
  public init(kcal:Double=0,protein:Double=0,fat:Double=0,carbohydrate:Double=0) throws {self.kcal=kcal;self.protein=protein;self.fat=fat;self.carbohydrate=carbohydrate;try validate()}
  public func validate() throws {guard [kcal,protein,fat,carbohydrate].allSatisfy({$0.isFinite && abs($0)<=100_000}) else {throw GoalFailure.invalidValue}}
}
public enum GoalPhase:String,Codable,Sendable {case gaining,maintaining,cutting}
public struct GoalRule:Codable,Equatable,Sendable,Identifiable {
  public let id:String,revision:Int,effectiveFrom:String,effectiveThrough:String?,phase:GoalPhase,base:GoalValues
  public init(id:String=UUID().uuidString,revision:Int=1,effectiveFrom:String,effectiveThrough:String?=nil,phase:GoalPhase,base:GoalValues) throws {
    self.id=id;self.revision=revision;self.effectiveFrom=effectiveFrom;self.effectiveThrough=effectiveThrough;self.phase=phase;self.base=base;try validate()
  }
  public func validate() throws {
    try FoodRules.id(id);try FoodRules.date(effectiveFrom);if let effectiveThrough {try FoodRules.date(effectiveThrough);guard effectiveThrough>=effectiveFrom else {throw GoalFailure.invalidValue}}
    try base.validate();guard revision>0,base.kcal != nil else {throw GoalFailure.invalidValue}
  }
  public func applies(_ date:String) throws -> Bool {try FoodRules.date(date);return date>=effectiveFrom && (effectiveThrough.map {date<=$0} ?? true)}
}
public struct ManualGoalAdjustment:Codable,Equatable,Sendable,Identifiable {
  public let id:String,date:String,reason:String,delta:GoalDelta
  public init(id:String=UUID().uuidString,date:String,reason:String,delta:GoalDelta) throws {self.id=id;self.date=date;self.reason=reason;self.delta=delta;try validate()}
  public func validate() throws {try FoodRules.id(id);try FoodRules.date(date);try FoodRules.text(reason);try delta.validate()}
}
public enum GoalSnapshotState:String,Codable,Sendable {case provisional,frozen}
/// 保存済みの基準と手動内訳だけから作る。PFCをkcalから暗黙に換算しません。
public struct DailyGoal:Codable,Equatable,Sendable {
  public let date:String,ruleID:String,ruleRevision:Int,calculationVersion:String,phase:GoalPhase,base:GoalValues,manual:[ManualGoalAdjustment],total:GoalValues,state:GoalSnapshotState
  private init(date:String,rule:GoalRule,manual:[ManualGoalAdjustment],state:GoalSnapshotState) throws {
    self.date=date;ruleID=rule.id;ruleRevision=rule.revision;calculationVersion="fixed-manual-v1";phase=rule.phase;base=rule.base;self.manual=manual;self.state=state
    var values=rule.base;for adjustment in manual {values=try values.adding(adjustment.delta)};total=values;try validate()
  }
  public static func calculate(date:String,rule:GoalRule?,manual:[ManualGoalAdjustment]=[],existing:DailyGoal?=nil,freeze:Bool=false) throws -> DailyGoal? {
    try FoodRules.date(date);if let existing {try existing.validate();guard existing.date==date else {throw GoalFailure.invalidValue};if existing.state == .frozen {return existing}}
    guard let rule else {guard manual.isEmpty else {throw GoalFailure.missingBase};return nil}
    try rule.validate();guard try rule.applies(date) else {return nil}
    for adjustment in manual {try adjustment.validate();guard adjustment.date==date else {throw GoalFailure.invalidValue}}
    guard Set(manual.map(\.id)).count==manual.count else {throw GoalFailure.invalidValue}
    return try .init(date:date,rule:rule,manual:manual,state:freeze ? .frozen:.provisional)
  }
  public func validate() throws {
    try FoodRules.date(date);try FoodRules.id(ruleID);try base.validate();try total.validate()
    guard ruleRevision>0,calculationVersion=="fixed-manual-v1",Set(manual.map(\.id)).count==manual.count else {throw GoalFailure.invalidValue}
    var expected=base;for a in manual {try a.validate();guard a.date==date else {throw GoalFailure.invalidValue};expected=try expected.adding(a.delta)}
    guard expected==total else {throw GoalFailure.invalidValue}
  }
  public func remaining(consumed:GoalValues) throws -> GoalRemainder {
    try consumed.validate()
    func value(_ goal:Double?,_ eaten:Double?) -> Double? {guard let goal,let eaten else {return nil};return goal-eaten}
    return .init(kcal:value(total.kcal,consumed.kcal),protein:value(total.protein,consumed.protein),fat:value(total.fat,consumed.fat),carbohydrate:value(total.carbohydrate,consumed.carbohydrate))
  }

}
public struct GoalRemainder:Equatable,Sendable {public let kcal:Double?,protein:Double?,fat:Double?,carbohydrate:Double?}
public enum FoodDayStatus:String,Codable,Sendable {case incomplete,completed,changed}
public struct FoodDay:Codable,Equatable,Sendable {
  public let date:String
  public private(set) var revision:Int,foodRevision:Int,status:FoodDayStatus,completedFoodRevision:Int?,completedAt:Date?,completionOperationID:String?
  public init(date:String,foodRevision:Int=0) throws {try FoodRules.date(date);guard foodRevision>=0 else {throw GoalFailure.invalidValue};self.date=date;revision=1;self.foodRevision=foodRevision;status = .incomplete}
  public static func completed(date:String,foodRevision:Int=0,operationID:String,at:Date) throws -> FoodDay {
    var day=try FoodDay(date:date,foodRevision:foodRevision)
    try day.complete(expectedFoodRevision:foodRevision,operationID:operationID,at:at)
    day.revision=1;try day.validate();return day
  }
  public mutating func complete(expectedFoodRevision:Int,operationID:String,at:Date) throws {
    try FoodRules.id(operationID);guard at.timeIntervalSince1970.isFinite,expectedFoodRevision==foodRevision else {throw GoalFailure.revisionConflict}
    if completionOperationID==operationID {guard status == .completed,completedFoodRevision==foodRevision,completedAt==at else {throw GoalFailure.revisionConflict};return}
    revision+=1;status = .completed;completedFoodRevision=foodRevision;completedAt=at;completionOperationID=operationID
  }
  public mutating func foodChanged(to next:Int) throws {guard next>foodRevision else {throw GoalFailure.revisionConflict};foodRevision=next;revision+=1;if status == .completed {status = .changed}}
  public func validate() throws {
    try FoodRules.date(date);guard revision>0,foodRevision>=0 else {throw GoalFailure.invalidValue}
    if status == .incomplete {guard completedFoodRevision==nil,completedAt==nil,completionOperationID==nil else {throw GoalFailure.invalidValue}}
    else {guard let completedFoodRevision,completedFoodRevision>=0,let completedAt,completedAt.timeIntervalSince1970.isFinite,let completionOperationID else {throw GoalFailure.invalidValue};try FoodRules.id(completionOperationID);guard status == .completed ? completedFoodRevision==foodRevision:completedFoodRevision<foodRevision else {throw GoalFailure.invalidValue}}
  }
  public var eligibleForPeriodAdjustment:Bool {status == .completed && completedFoodRevision==foodRevision}
}
