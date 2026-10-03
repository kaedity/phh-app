#if DEBUG
import SwiftUI
import PHHHubCore

struct PreviewDisplay: ViewModifier {
    func body(content: Content) -> some View {
        let args = ProcessInfo.processInfo.arguments
        let reduction = args.contains("--reduce-motion")
        let scheme: ColorScheme? = args.contains("--dark") ? .dark : args.contains("--light") ? .light : nil
        if args.contains("--ax5") { content.preferredColorScheme(scheme).environment(\.dynamicTypeSize, .accessibility5).environment(\.motionReductionOverride, reduction) }
        else { content.preferredColorScheme(scheme).environment(\.motionReductionOverride, reduction) }
    }
}

// 主要導線を実物確認するための合成表示。認証・Keychain・現用DB・通信を使いません。
struct HubPreviewRoot: View {
    @State private var model: HubModel?
    @State private var issue: String?
    var body: some View {
        Group {
            if let model { HubRoot(model: model) }
            else { Text(issue ?? "合成表示を準備しています") }
        }.task {
            guard model == nil, issue == nil else { return }
            do {
                let args = ProcessInfo.processInfo.arguments
                let empty = args.contains("--empty"), failure = args.contains("--failure")
                let hub = PlanningPreviewRoot.makeStore(empty: empty)
                let now = TrainingPreviewData.date
                let scope = try HealthQueryScope(deviceID: UUID().uuidString, metric: .bodyMass, phase: .recent, lowerBound: now.addingTimeInterval(-30*86400))
                try hub.registerHealthScope(scope)
                if !empty {
                    let source = try HealthSource(id: "synthetic.eufy", name: "Eufy · 架空データ", device: "P2 Pro")
                    let samples = try (0..<14).map { index in
                        let date = now.addingTimeInterval(-Double(index + (index > 5 ? 2 : 0))*86400)
                        return try HealthSample(id: UUID().uuidString, metric: .bodyMass, source: source, start: date, end: date, value: 68 + Double(index % 3)*0.2, unit: "kg")
                    }
                    try hub.ingestHealth(HealthImportPage(scopeID: scope.id, expectedAnchor: nil, nextAnchor: Data([1]), added: samples, deletedIDs: [], hasMore: false, receivedAt: now), synthetic: true)
                    if failure { try hub.markHealthReadFailure(scope.id, state: .temporaryFailure) }
                    if args.contains("--history-partial") {
                        let history = try HealthQueryScope(deviceID: scope.deviceID, metric: .bodyMass, phase: .history, lowerBound: now.addingTimeInterval(-365*86400), upperBound: scope.lowerBound)
                        try hub.registerHealthScope(history)
                        try hub.ingestHealth(HealthImportPage(scopeID: history.id, expectedAnchor: nil, nextAnchor: Data([2]), added: [], deletedIDs: [], hasMore: true, receivedAt: now), synthetic: true)
                    }
                }
                if args.contains("--pending") || failure {
                    let queued = HubOperation(action: "confirm_meal", meal: SyntheticMeal(date: "2026-10-02"))
                    try hub.enqueue(queued)
                    if failure {
                        let rejected = HubOperation(action: "confirm_meal", meal: SyntheticMeal(date: "2026-10-02"))
                        try hub.enqueue(rejected)
                        try hub.deferOperation(rejected.id, state: .conflict, message: "要確認：REVISION_CONFLICT（合成表示）", retryAt: now)
                    }
                }
                model = try HubModel(previewStore: hub, empty: empty, syncing: args.contains("--syncing"), failure: failure)
            } catch { issue = "合成表示を準備できませんでした：\(error)" }
        }
    }
}
#endif
