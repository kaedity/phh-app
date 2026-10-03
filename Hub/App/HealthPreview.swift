#if DEBUG
import SwiftUI
import PHHHubCore
struct HealthPreviewRoot: View {
    @State private var screen: HealthScreenModel?
    @State private var issue: String?
    var body: some View {
        NavigationStack { if let screen { if ProcessInfo.processInfo.arguments.contains("--weight") { HealthWeightPage(screen: screen) } else { HealthDetailPage(screen: screen) } } else { Text(issue ?? "合成データを準備しています") } }.tint(pine)
            .task { guard screen == nil else { return }; do {
                let store = try HubStore(owner: "synthetic-health-preview@example.test"), now = Date(), device = UUID().uuidString
                let source = try HealthSource(id: "synthetic.eufy", name: "Eufy · 架空データ", device: "P2 Pro")
                let scope = try HealthQueryScope(deviceID: device, metric: .bodyMass, phase: .recent, lowerBound: now.addingTimeInterval(-30*86400)); try store.registerHealthScope(scope)
                let samples = try (0..<14).map { index in
                    let date = now.addingTimeInterval(-Double(index + (index > 5 ? 2 : 0))*86400)
                    return try HealthSample(id: UUID().uuidString, metric: .bodyMass, source: source, start: date, end: date, value: 68 + Double(index % 3)*0.2, unit: "kg")
                }
                try store.ingestHealth(HealthImportPage(scopeID: scope.id, expectedAnchor: nil, nextAnchor: Data([1]), added: samples, deletedIDs: [], hasMore: false, receivedAt: now), synthetic: true)
                screen = try HealthScreenModel(store: store, date: HealthDates.local(now))
            } catch { issue = "合成データを準備できませんでした" } }
    }
}
#endif
