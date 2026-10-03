import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct FoodQueuedEditTests {
    @Test func editsWhileFirstWriteIsInFlightKeepVersionsAndLatestValueAcrossRestart() throws {
        let fixture = try FoodHubTests().fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hub.sqlite")
        let hub = try HubStore(url: url, owner: "synthetic@example.test")
        try hub.apply(fixture.page)
        let food = FoodHubStore(hub: hub)
        let twice = try fixture.meal.edited(factor: 2)
        let firstID = try food.enqueue(twice, operationID: UUID().uuidString)
        try hub.markAttempted(firstID)
        let threeTimes = try twice.edited(factor: 1.5)
        let secondID = try food.enqueue(threeTimes, operationID: UUID().uuidString)
        #expect(try hub.pending().map(\.operation.expected_revision) == [1, 2])
        let reopened = try HubStore(url: url, owner: "synthetic@example.test")
        let snapshot = try FoodHubStore(hub: reopened).snapshot()
        let displayed = try FoodDayPresentation(date: fixture.meal.date, snapshot: snapshot)
        #expect(snapshot.pending.map(\.id) == [firstID, secondID])
        #expect(displayed.meals == [threeTimes])
        #expect(displayed.reviewIDs.isEmpty)
        #expect(displayed.localTotal.known[.kcal] == 300)
        #expect(displayed.localTotal.known[.protein] == 30)
        #expect(displayed.localTotal.known[.fat] == 0)
        #expect(displayed.localTotal.known[.carbohydrate] == 90)
        #expect(displayed.localTotal.missing[.kcal] == 1)
        #expect(displayed.localTotal.missing[.carbohydrate] == 0)
    }

    func accept(_ operation: HubOperation, in hub: HubStore) throws {
        try hub.finish(.init(environment: hubEnvironment, operation_id: operation.id, status: "committed",
            entity_ids: [operation.entity_id], revisions: [operation.expected_revision + 1], retryable: false), operation: operation)
    }

    @Test func receiptBeforeReadbackKeepsLatestValueAndAllowsNextEditAfterRestart() throws {
        let fixture = try FoodHubTests().fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hub.sqlite")
        let hub = try HubStore(url: url, owner: "synthetic@example.test")
        try hub.apply(fixture.page)
        let food = FoodHubStore(hub: hub), twice = try fixture.meal.edited(factor: 2)
        let firstID = try food.enqueue(twice, operationID: UUID().uuidString)
        let first = try #require(hub.pending().first?.operation)
        let third = try twice.edited(factor: 1.5)
        let secondID = try food.enqueue(third, operationID: UUID().uuidString)
        try accept(first, in: hub)
        try accept(first, in: hub)
        let reopened = try HubStore(url: url, owner: "synthetic@example.test")
        let restored = FoodHubStore(hub: reopened), state = try restored.snapshot()
        #expect(state.confirmed == [fixture.meal])
        #expect(state.acknowledged == [twice])
        #expect(state.pending.map(\.id) == [secondID])
        #expect(!state.pending.contains { $0.id == firstID })
        #expect(try FoodDayPresentation(date: fixture.meal.date, snapshot: state).meals == [third])
        let second = try #require(reopened.pending().first?.operation)
        try accept(second, in: reopened)
        #expect(try restored.snapshot().acknowledged == [third])
        try restored.edit(fixture.meal.id, factor: 1, date: "2026-10-02")
        let next = try #require(reopened.pending().first?.operation)
        #expect(next.expected_revision == 3)
        #expect(next.foodMeal?.date == "2026-10-02")
        #expect(try FoodDayPresentation(date: fixture.meal.date, snapshot: restored.snapshot()).meals.isEmpty)
        #expect(try FoodDayPresentation(date: "2026-10-02", snapshot: restored.snapshot()).meals.count == 1)
    }

    @Test func canonicalReadbackRetiresAcknowledgementWithoutRevertingTheValue() throws {
        let fixture = try FoodHubTests().fixture(), hub = try HubStore(owner: "synthetic@example.test")
        try hub.apply(fixture.page)
        let food = FoodHubStore(hub: hub), twice = try fixture.meal.edited(factor: 2)
        _ = try food.enqueue(twice, operationID: UUID().uuidString)
        try accept(#require(hub.pending().first?.operation), in: hub)
        var page = fixture.page
        page.changes = page.changes.filter { ["Meals", "MealItems", "IntakeNutrients"].contains($0.change.table_name) }
        for index in page.changes.indices {
            page.changes[index].change.change_number = fixture.page.next_cursor + index + 1
            page.changes[index].change.revision = 2
            page.changes[index].change.indexed_revision = 2
            page.changes[index].record["revision"] = .number(2)
            for field in ["quantity", "value"] {
                if let value = page.changes[index].record[field]?.number { page.changes[index].record[field] = .number(value * 2) }
            }
        }
        page.next_cursor = fixture.page.next_cursor + page.changes.count
        page.snapshot_revision = page.next_cursor
        try hub.apply(page)
        let state = try food.snapshot()
        #expect(state.confirmed == [twice])
        #expect(state.acknowledged.isEmpty)
        #expect(state.pending.isEmpty)
        #expect(try FoodDayPresentation(date: fixture.meal.date, snapshot: state).meals == [twice])
    }

    @Test func staleVersionsChangedResendsAndConflictedChainsCannotOverwriteValues() throws {
        let fixture = try FoodHubTests().fixture(), hub = try HubStore(owner: "synthetic@example.test")
        try hub.apply(fixture.page)
        let food = FoodHubStore(hub: hub), twice = try fixture.meal.edited(factor: 2)
        let firstID = try food.enqueue(twice, operationID: UUID().uuidString)
        #expect(try food.enqueue(twice, operationID: firstID) == firstID)
        #expect(throws: HubError.invalidOperation) { try food.enqueue(fixture.meal.edited(factor: 3), operationID: firstID) }
        #expect(throws: FoodFailure.revisionConflict) { try food.enqueue(fixture.meal.edited(factor: 3), operationID: UUID().uuidString) }
        try hub.deferOperation(firstID, state: .conflict, message: "REVISION_CONFLICT", retryAt: .now)
        #expect(throws: FoodFailure.pendingEdit) { try food.edit(fixture.meal.id, factor: 1.5) }
        let state = try food.snapshot(), projection = try FoodDayPresentation(date: fixture.meal.date, snapshot: state)
        #expect(projection.reviewIDs == [firstID])
        #expect(projection.meals == [fixture.meal])
        #expect(try hub.pending().count == 1)
    }

    @Test func undoingTailKeepsInFlightHeadAndRejectsUndoThatWouldBreakTheChain() throws {
        let fixture = try FoodHubTests().fixture(), hub = try HubStore(owner: "synthetic@example.test")
        try hub.apply(fixture.page)
        let food = FoodHubStore(hub: hub), twice = try fixture.meal.edited(factor: 2), now = Date.now
        let firstID = try food.enqueue(twice, operationID: UUID().uuidString)
        try hub.markAttempted(firstID)
        let third = try twice.edited(factor: 1.5)
        let secondID = try food.enqueue(third, operationID: UUID().uuidString)
        let head = try FoodUndoChange(operationID: firstID, before: fixture.meal, after: twice, at: now)
        #expect(throws: FoodFailure.pendingEdit) { try food.undoChange(head, at: now) }
        let tail = try FoodUndoChange(operationID: secondID, before: twice, after: third, at: now)
        try food.undoChange(tail, at: now)
        #expect(try hub.pending().map(\.id) == [firstID])
        #expect(try FoodDayPresentation(date: fixture.meal.date, snapshot: food.snapshot()).meals == [twice])
    }

    @Test func undoAfterReceiptDoesNotWaitForCanonicalReadback() throws {
        let fixture = try FoodHubTests().fixture(), hub = try HubStore(owner: "synthetic@example.test")
        try hub.apply(fixture.page)
        let food = FoodHubStore(hub: hub), twice = try fixture.meal.edited(factor: 2), now = Date.now
        let firstID = try food.enqueue(twice, operationID: UUID().uuidString)
        try accept(#require(hub.pending().first?.operation), in: hub)
        let change = try FoodUndoChange(operationID: firstID, before: fixture.meal, after: twice, at: now)
        try food.undoChange(change, at: now)
        let restored = try #require(hub.pending().first?.operation)
        #expect(restored.expected_revision == 2)
        #expect(restored.foodMeal?.items == fixture.meal.items)
        #expect(try FoodDayPresentation(date: fixture.meal.date, snapshot: food.snapshot()).localTotal.known[.kcal] == 100)
    }

    @Test func originalAdditionCannotBeUndoneWhileLaterEditsDependOnIt() throws {
        let fixture = try FoodHubTests().fixture(), hub = try HubStore(owner: "synthetic@example.test")
        try FoodHubTests().ready(hub)
        let food = FoodHubStore(hub: hub)
        let addition = try food.enqueue(fixture.meal, operationID: UUID().uuidString)
        let twice = try fixture.meal.edited(factor: 2)
        let edit = try food.enqueue(twice, operationID: UUID().uuidString)
        #expect(throws: FoodFailure.pendingEdit) { try food.undoAddition(addition) }
        #expect(try hub.pending().map(\.id) == [addition, edit])
    }
}
