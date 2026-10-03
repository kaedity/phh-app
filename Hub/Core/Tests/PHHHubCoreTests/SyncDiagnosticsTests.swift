import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct SyncDiagnosticsTests {
    @Test func stagesAggregateTimeAndBytesWithoutPersistingRequestContent() throws {
        var now = 10.0
        let recorder = SyncTimingRecorder(clock: { now })
        let first = recorder.begin(.http); now += 2; recorder.end(first, requestBytes: 100, responseBytes: 200)
        let next = recorder.begin(.http); now += 1; recorder.end(next, requestBytes: 300, responseBytes: 400)
        #expect(recorder.metrics.count == 1)
        let metric = recorder.metrics[0]
        #expect(metric.elapsedSeconds == 3); #expect(metric.calls == 2)
        #expect(metric.requestBytes == 400); #expect(metric.responseBytes == 600)
        let data = try JSONEncoder().encode(recorder.metrics)
        let keys = Set((try JSONSerialization.jsonObject(with: data) as! [[String: Any]])[0].keys)
        #expect(keys == Set(["stage", "elapsedSeconds", "calls", "itemCount", "requestBytes", "responseBytes"]))
        #expect(try JSONDecoder().decode([SyncTimingMetric].self, from: data) == recorder.metrics)
        recorder.reset(); #expect(recorder.metrics.isEmpty)
    }
    @Test func failedStorageWorkStillRecordsTimeWithoutChangingError() throws {
        var now = 0.0
        let recorder = SyncTimingRecorder(clock: { now })
        #expect(throws: HubError.invalidResponse) {
            try recorder.measure(.deltaApply, items: 3) { now = 0.25; throw HubError.invalidResponse }
        }
        #expect(recorder.metrics[0].elapsedSeconds == 0.25); #expect(recorder.metrics[0].itemCount == 3)
    }
}
