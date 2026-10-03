import Foundation
import CryptoKit
import Testing
@testable import PHHHubCore

/// Opt-in local pipeline benchmark. The transport is a mock; no network, GAS, or HealthKit read occurs.
@Suite @MainActor struct SyncPipelineBenchmarkTests {
    @Test func synchronizePipelineBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["PHH_SYNC_PIPELINE_BENCHMARK"] == "1" else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try HubStore(url: dir.appendingPathComponent("hub.sqlite"), owner: "synthetic@example.test")
        let fixture = try HubCoreTests().fixture()
        let operations = (0..<100).map { index in
            var operation = fixture.operation
            operation.operation_id = String(format: "00000000-0000-4000-a000-%012d", 200_000 + index); operation.entity_id = String(format: "00000000-0000-4000-a000-%012d", 300_000 + index)
            return operation
        }
        try store.enqueueBatch(operations)
        let transport = PipelineTimingTransport(), clock = ContinuousClock(), start = clock.now
        let engine = SyncEngine(store: store, transport: transport)
        await engine.synchronize(date: "2026-10-03")
        let elapsed = PipelineTimingTransport.seconds(start.duration(to: clock.now))
        #expect(transport.operationIDs == operations.map(\.id))
        #expect(transport.intakeCalls == 1 && transport.deltaCalls == 1)
        #expect(engine.lastFailureCode == nil); #expect(try store.pending().isEmpty)
        let encoding = JSONEncoder(); encoding.outputFormatting = [.sortedKeys]
        let inputHash = SHA256.hash(data: try encoding.encode(operations)).map { String(format: "%02x", $0) }.joined()
        print("PHH_SYNC_PIPELINE_BENCHMARK input_sha256=\(inputHash) backend=sqlite queued=100 resolve_calls=\(transport.operationIDs.count) intake_calls=\(transport.intakeCalls) delta_calls=\(transport.deltaCalls) total_seconds=\(elapsed) mock_transport_seconds=\(transport.elapsed) outside_transport_seconds=\(elapsed - transport.elapsed)")
    }
}
@MainActor private final class PipelineTimingTransport: HubTransport {
    var connected = true
    var operationIDs: [String] = []
    var intakeCalls = 0, deltaCalls = 0
    var elapsed = 0.0
    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components; return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
    func resolve(_ operation: HubOperation) async throws -> Receipt {
        let clock = ContinuousClock(), start = clock.now
        defer { elapsed += Self.seconds(start.duration(to: clock.now)) }
        operationIDs.append(operation.id)
        return Receipt(environment: hubEnvironment, operation_id: operation.id, status: "committed",
          entity_ids: [operation.entity_id], revisions: [operation.expected_revision + 1], retryable: false)
    }
    func result(_ operation: HubOperation) async throws -> Receipt { throw HubError.invalidOperation }
    func submit(_ operation: HubOperation) async throws -> Receipt { throw HubError.invalidOperation }
    func processIntake(date: String) async throws {
        let clock = ContinuousClock(), start = clock.now
        defer { elapsed += Self.seconds(start.duration(to: clock.now)) }; intakeCalls += 1
    }
    func delta(_ query: HubQuery) async throws -> Delta {
        let clock = ContinuousClock(), start = clock.now
        defer { elapsed += Self.seconds(start.duration(to: clock.now)) }; deltaCalls += 1
        return Delta(schema_version: 1, environment: hubEnvironment, generation: 1,
          snapshot_revision: query.after ?? 0, changes: [], next_cursor: query.after ?? 0, has_more: false)
    }
}
