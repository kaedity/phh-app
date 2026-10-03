import Foundation
import Testing
@testable import PHHHubCore

@Suite struct FoodDayPresentationTests {
    let day = "2026-10-03"
    func meal(_ kcal: Double?, date: String = "2026-10-03") throws -> FoodMeal {
        try .init(date: date, slot: "朝食", items: [.init(name: "架空の食事", quantity: 1, unit: "個", source: "本人", nutrients: .init(kcal: kcal, protein: 10, fat: 0, carbohydrate: 15))])
    }
    func snapshot(_ confirmed: [FoodMeal], _ pending: [FoodPendingOperation]) throws -> FoodScreenSnapshot {
        .init(catalog: try .init(), confirmed: confirmed, pending: pending)
    }
    @Test func localAdditionIsCountedOnceBeforeAndAfterAcknowledgement() throws {
        let original = try meal(600), added = try meal(100), operation = try FoodPendingOperation(expectedRevision: 0, meal: added)
        let local = try FoodDayPresentation(date: day, snapshot: snapshot([original], [operation]))
        let saved = try FoodDayPresentation(date: day, snapshot: snapshot([original, added], []))
        #expect(local.confirmedTotal.known[.kcal] == 600)
        #expect(local.localTotal == saved.localTotal)
        #expect(local.localTotal.known[.kcal] == 700)
        #expect(local.pending.map(\.id) == [operation.id])
    }
    @Test func updateDateMoveAndCancellationReplaceOriginalInsteadOfAddingAgain() throws {
        let original = try meal(100), changed = try original.edited(factor: 2, date: "2026-10-04"), operation = try FoodPendingOperation(expectedRevision: 1, meal: changed)
        let state = try snapshot([original], [operation])
        let old = try FoodDayPresentation(date: day, snapshot: state), next = try FoodDayPresentation(date: "2026-10-04", snapshot: state)
        #expect(old.localTotal.known[.kcal] == 0); #expect(next.localTotal.known[.kcal] == 200)
        #expect(old.pending.map(\.id) == [operation.id]); #expect(next.pending.map(\.id) == [operation.id])
        let canceled = try FoodPendingOperation(expectedRevision: 1, meal: original.edited(remove: true))
        #expect(try FoodDayPresentation(date: day, snapshot: snapshot([original], [canceled])).meals.isEmpty)
    }
    @Test func rejectedAndStaleUpdatesKeepPreviousValueAndUnrelatedDayIsExcluded() throws {
        let original = try meal(100), changed = try original.edited(factor: 2)
        var rejected = try FoodPendingOperation(expectedRevision: 1, meal: changed); rejected.state = .needsReview
        let review = try FoodDayPresentation(date: day, snapshot: snapshot([original], [rejected]))
        #expect(review.localTotal.known[.kcal] == 100); #expect(review.reviewIDs == [rejected.id])
        rejected.state = .queued
        let stale = try FoodDayPresentation(date: day, snapshot: snapshot([changed], [rejected]))
        #expect(stale.localTotal.known[.kcal] == 200); #expect(stale.reviewIDs == [rejected.id])
        #expect(try FoodDayPresentation(date: "2026-10-05", snapshot: snapshot([original], [rejected])).pending.isEmpty)
    }
    @Test func undoOfAttemptedAdditionDoesNotChangeOtherMealOrOperationIdentity() throws {
        let original = try meal(600), added = try meal(100)
        var operation = try FoodPendingOperation(expectedRevision: 0, meal: added); operation.attempted = true; operation.undoRequested = true
        let projected = try FoodDayPresentation(date: day, snapshot: snapshot([original], [operation]))
        #expect(projected.localTotal.known[.kcal] == 600); #expect(projected.pending == [operation])
    }
    @Test func knownPartialTotalsAndZeroRemainDistinctFromMissingWhenAddingSupplement() throws {
        let food = try FoodDayPresentation(date: day, snapshot: snapshot([meal(nil)], [])).localTotal
        #expect(food.displayValue(for:.kcal) == nil)
        #expect(FoodTotal(items:[]).displayValue(for:.kcal) == 0)
        let knownZero = try FoodTotal.day(day,meals:[meal(0),meal(nil)])
        #expect(knownZero.displayValue(for:.kcal) == 0 && knownZero.missing[.kcal] == 1)
        let product = try SupplementProductVersion(productID: UUID().uuidString, name: "架空のサプリ", referenceAmount: 1, unit: "個", nutrients: [
            .init(nutrientID: "kcal", value: 20, unit: "kcal", source: "本人"), .init(nutrientID: "protein", value: 1, unit: "g", source: "本人"),
            .init(nutrientID: "fat", value: 0, unit: "g", source: "本人"), .init(nutrientID: "carbohydrate", value: nil, unit: "g", source: "本人")])
        let plan = try SupplementPlanVersion(productVersionID: product.id, dailyAmount: 1, effectiveFrom: day)
        var ledger = try SupplementLedger(products: [product], plans: [plan])
        try ledger.materialize(planID: plan.planID, date: day, today: day)
        let supplement = ledger.days[0]
        let total = try food.includingSupplements([supplement], date: day)
        #expect(total.known[.kcal] == 20); #expect(total.missing[.kcal] == 1)
        #expect(total.displayValue(for:.kcal) == 20 && total.displayValue(for:.carbohydrate) == 15)
        let supplementOnly = try FoodTotal(items:[]).includingSupplements([supplement],date:day)
        #expect(supplementOnly.displayValue(for:.fat) == 0 && supplementOnly.displayValue(for:.carbohydrate) == nil)
        #expect(total.known[.fat] == 0); #expect(try total.goalValues().fat == 0)
        #expect(try total.goalValues().kcal == nil); #expect(try total.goalValues().carbohydrate == nil)
    }
}
