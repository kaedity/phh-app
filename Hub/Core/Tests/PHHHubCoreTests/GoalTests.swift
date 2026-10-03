import Foundation
import Testing
@testable import PHHHubCore

@Suite struct GoalTests {
  func rule(_ start:String="2026-10-03",kcal:Double=2000) throws -> GoalRule {try .init(effectiveFrom:start,phase:.maintaining,base:.init(kcal:kcal,protein:100,fat:50,carbohydrate:250))}
  @Test func unsetAndBeforeEffectiveDateStayUnsetAndExplicitMacrosAreNotRecalculated() throws {
    #expect(try DailyGoal.calculate(date:"2026-10-03",rule:nil)==nil)
    #expect(try DailyGoal.calculate(date:"2026-10-02",rule:rule())==nil)
    let goal=try DailyGoal.calculate(date:"2026-10-03",rule:rule())!
    #expect(goal.total.kcal==2000);#expect(goal.total.protein==100);#expect(goal.total.carbohydrate==250)
  }
  @Test func manualPartsOnlyAffectExplicitNutrientsAndOverageIsNegativeRemaining() throws {
    let adjustment=try ManualGoalAdjustment(date:"2026-10-03",reason:"架空の手動調整",delta:.init(kcal:100))
    let goal=try DailyGoal.calculate(date:"2026-10-03",rule:rule(),manual:[adjustment])!
    #expect(goal.total.kcal==2100);#expect(goal.total.protein==100);#expect(goal.manual==[adjustment]);#expect(goal.calculationVersion=="fixed-manual-v1")
    #expect(try goal.remaining(consumed:.init(kcal:2200,protein:120,fat:55,carbohydrate:260)).kcal == -100)
  }
  @Test func frozenDateKeepsOldRuleAndManualAfterNewRuleArrives() throws {
    let old=try DailyGoal.calculate(date:"2026-10-03",rule:rule(),freeze:true)!
    let newer=try rule(kcal:2400),manual=try ManualGoalAdjustment(date:"2026-10-03",reason:"架空",delta:.init(kcal:200))
    #expect(try DailyGoal.calculate(date:"2026-10-03",rule:newer,manual:[manual],existing:old)==old)
    let bytes=try JSONEncoder().encode(old),restored=try JSONDecoder().decode(DailyGoal.self,from:bytes);try restored.validate();#expect(restored==old)
  }
  @Test func missingMacroIsNotZeroAndCannotBeAdjustedWithoutBase() throws {
    let base=try GoalRule(effectiveFrom:"2026-10-03",phase:.cutting,base:.init(kcal:1800)),goal=try DailyGoal.calculate(date:"2026-10-03",rule:base)!
    #expect(goal.total.protein==nil);let remaining=try goal.remaining(consumed:.init(kcal:1900));#expect(remaining.kcal == -100);#expect(remaining.protein==nil)
    let a=try ManualGoalAdjustment(date:"2026-10-03",reason:"架空",delta:.init(protein:10))
    #expect(throws:GoalFailure.missingBase){try DailyGoal.calculate(date:"2026-10-03",rule:base,manual:[a])}
  }
  @Test func incompleteAndChangedDaysAreNeverEligibleUntilExplicitlyCompletedAgain() throws {
    var day=try FoodDay(date:"2026-10-03"),op=UUID().uuidString;let at=Date(timeIntervalSince1970:100)
    #expect(!day.eligibleForPeriodAdjustment)
    try day.complete(expectedFoodRevision:0,operationID:op,at:at);let before=day
    try day.complete(expectedFoodRevision:0,operationID:op,at:at);#expect(day==before)
    try day.foodChanged(to:1);#expect(day.status == .changed);#expect(!day.eligibleForPeriodAdjustment);#expect(day.completedAt==at)
    #expect(throws:GoalFailure.revisionConflict){try day.complete(expectedFoodRevision:0,operationID:UUID().uuidString,at:at)}
    op=UUID().uuidString;try day.complete(expectedFoodRevision:1,operationID:op,at:at.addingTimeInterval(1));#expect(day.eligibleForPeriodAdjustment)
  }
  @Test func invalidDatesNumbersDuplicateManualAndNegativeResultReject() throws {
    #expect(throws:(any Error).self){try rule("2026-02-30")};#expect(throws:GoalFailure.invalidValue){try GoalDelta(kcal:.nan)}
    let a=try ManualGoalAdjustment(date:"2026-10-03",reason:"架空",delta:.init(kcal:-3000))
    #expect(throws:GoalFailure.invalidValue){try DailyGoal.calculate(date:"2026-10-03",rule:rule(),manual:[a])}
    #expect(throws:GoalFailure.invalidValue){try DailyGoal.calculate(date:"2026-10-03",rule:rule(),manual:[a,a])}
  }
}
