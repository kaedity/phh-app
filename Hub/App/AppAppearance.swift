import SwiftUI

/// 外観は端末内の設定。架空データの画面試験は通常利用と保存先を分ける。
enum AppAppearance: String, CaseIterable {
    case light, dark
    var title: String { self == .light ? "ライトモード" : "ダークモード" }
    var scheme: ColorScheme { self == .light ? .light : .dark }
    static let key = "phh.appearance.mode"
    static func resolved(_ value: String) -> Self { Self(rawValue: value) ?? .dark }
    @MainActor static let defaults: UserDefaults = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--p") && $0.hasSuffix("-preview") }) {
            return UserDefaults(suiteName: "jp.personalhealthhub.appearance.synthetic")!
        }
        #endif
        return .standard
    }()
    #if DEBUG
    @MainActor static func prepareSyntheticIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(where: { $0.hasPrefix("--p") && $0.hasSuffix("-preview") }) else { return }
        if args.contains("--appearance-unset") { defaults.removeObject(forKey: key) }
        if args.contains("--appearance-invalid") { defaults.set("invalid", forKey: key) }
    }
    #endif
}

struct AppAppearanceDisplay: ViewModifier {
    // 本人指定の初期値はダーク（ナイト）。端末の設定には連動しない。
    @AppStorage(AppAppearance.key, store: AppAppearance.defaults) private var selected = AppAppearance.dark.rawValue
    private var scheme: ColorScheme {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--dark") { return .dark }
        if args.contains("--light") { return .light }
        #endif
        return AppAppearance.resolved(selected).scheme
    }
    func body(content: Content) -> some View { content.preferredColorScheme(scheme) }
}

struct AppAppearanceCard: View {
    @AppStorage(AppAppearance.key, store: AppAppearance.defaults) private var selected = AppAppearance.dark.rawValue
    var body: some View {
        HubMockCard {
            Text("外観").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { choices }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 12) { choices }
            }
        }
    }
    @ViewBuilder private var choices: some View {
        ForEach(AppAppearance.allCases, id: \.self) { mode in
            Button { selected = mode.rawValue } label: {
                Label(mode.title, systemImage: AppAppearance.resolved(selected) == mode ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.bordered)
            .tint(AppAppearance.resolved(selected) == mode ? pine : .secondary)
            .accessibilityAddTraits(AppAppearance.resolved(selected) == mode ? .isSelected : [])
        }
    }
}
