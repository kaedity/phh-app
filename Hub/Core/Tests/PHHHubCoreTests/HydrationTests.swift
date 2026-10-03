import Foundation
import Testing
@testable import PHHHubCore

struct HydrationTests {
  @Test func defaultAmountDoesNotInventGoal() throws {
    let preferences=try HydrationPreferences()
    #expect(preferences.addAmountML == 250)
    let record=try HydrationRecord(date:"2026-10-03",amountML:preferences.addAmountML)
    let summary=try HydrationAggregation.day("2026-10-03",records:[record],preferences:preferences)
    #expect(summary.totalML == 250 && summary.recordCount == 1)
    #expect(summary.goalML == nil && summary.remainingML == nil && summary.progress == nil)
    let data=try JSONEncoder().encode(preferences)
    #expect(try JSONDecoder().decode(HydrationPreferences.self,from:data) == preferences)
  }

  @Test func replayEditDateMoveAndRemovalUseSameRecord() throws {
    let id=UUID().uuidString, preferences=try HydrationPreferences(dailyGoalML:1000)
    let first=try HydrationRecord(id:id,date:"2026-10-03",amountML:250)
    let changed=try HydrationRecord(id:id,date:"2026-10-03",revision:2,amountML:500)
    let other=try HydrationRecord(date:"2026-10-03",amountML:250)
    let summary=try HydrationAggregation.day("2026-10-03",records:[changed,first,changed,other],preferences:preferences)
    #expect(summary.totalML == 750 && summary.recordCount == 2 && summary.remainingML == 250)
    let moved=try HydrationRecord(id:id,date:"2026-10-02",revision:3,amountML:500)
    #expect(try HydrationAggregation.day("2026-10-03",records:[first,changed,moved,other],preferences:preferences).totalML == 250)
    let removed=try HydrationRecord(id:id,date:"2026-10-02",revision:4,amountML:500,removed:true)
    let restored=try HydrationRecord(id:id,date:"2026-10-02",revision:5,amountML:500)
    #expect(try HydrationAggregation.day("2026-10-02",records:[moved,removed,first],preferences:preferences).totalML == 0)
    #expect(try HydrationAggregation.day("2026-10-02",records:[removed,restored,moved],preferences:preferences).totalML == 500)
  }

  @Test func conflictingRevisionIsRejectedEvenAfterNewerVersion() throws {
    let id=UUID().uuidString, preferences=try HydrationPreferences()
    let first=try HydrationRecord(id:id,date:"2026-10-03",amountML:250)
    let conflicting=try HydrationRecord(id:id,date:"2026-10-03",amountML:300)
    let newer=try HydrationRecord(id:id,date:"2026-10-03",revision:2,amountML:500)
    #expect(throws:HydrationFailure.conflictingRevision) {
      try HydrationAggregation.day("2026-10-03",records:[newer,first,conflicting],preferences:preferences)
    }
  }

  @Test func invalidDecodedValuesAndOverflowCannotBecomeDailyTotals() throws {
    let invalid=try JSONDecoder().decode(HydrationPreferences.self,from:Data(#"{"addAmountML":-250,"dailyGoalML":0}"#.utf8))
    #expect(throws:HydrationFailure.invalidValue) { try invalid.validate() }
    #expect(throws:HydrationFailure.invalidValue) { try HydrationRecord(date:"2026-10-03",amountML:.nan) }
    #expect(throws:FoodFailure.invalidValue) { try HydrationRecord(date:"2026-02-30",amountML:250) }
    let large=try [HydrationRecord(date:"2026-10-03",amountML:.greatestFiniteMagnitude),HydrationRecord(date:"2026-10-03",amountML:.greatestFiniteMagnitude)]
    #expect(throws:HydrationFailure.invalidValue) {
      try HydrationAggregation.day("2026-10-03",records:large,preferences:HydrationPreferences())
    }
    let over=try HydrationAggregation.day("2026-10-03",records:[HydrationRecord(date:"2026-10-03",amountML:1250)],preferences:HydrationPreferences(dailyGoalML:1000))
    #expect(over.progress == 1 && over.remainingML == 0 && over.excessML == 250)
  }
}
