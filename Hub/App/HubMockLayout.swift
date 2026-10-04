import SwiftUI
import PHHHubCore

struct HubMockPage<Content: View>: View {
  var title = ""
  var showNavigation = false
  @ViewBuilder var content: Content
  var body: some View {
    ScrollView { VStack(alignment: .leading, spacing: 14) { content }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 128) }
      .background(canvas).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
      .toolbar(showNavigation ? .visible : .hidden, for: .navigationBar)
  }
}
struct HubMockCard<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) { content }.frame(maxWidth: .infinity, alignment: .leading)
      .padding(16).background(HubPalette.card, in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).stroke(pine.opacity(0.04)))
  }
}
struct HubMacroProgress: View {
  let title: String, symbol: String, value: Double?, target: Double?, color: Color
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(symbol).font(.caption.bold()).foregroundStyle(color)
        Text(foodNumber(value)).font(.headline)
        if let target { Text("/\(foodNumber(target))g").font(.caption2).foregroundStyle(.secondary) }
        else { Text("g").font(.caption2).foregroundStyle(.secondary) }
      }.lineLimit(1).minimumScaleFactor(0.7)
      GeometryReader { size in
        ZStack(alignment: .leading) {
          Capsule().fill(color.opacity(0.1))
          Capsule().fill(color).frame(width: size.size.width * CGFloat(value.flatMap { n in target.flatMap { $0 > 0 ? min(1,max(0,n/$0)) : nil } } ?? 0))
        }
      }.frame(height: 5)
      if let target {
        Text(value.map { $0 <= target ? "残り \(foodNumber(target-$0)) g" : "目標より＋\(foodNumber($0-target)) g" } ?? "残り — g").font(.caption2)
      } else { Text("目標未設定").font(.caption2) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct HubSettingsRow: View {
  @Environment(\.dynamicTypeSize) private var textSize
  var accessibilityStacked = false
  let title: String, subtitle: String, symbol: String
  var body: some View {
    Group {
      if accessibilityStacked && textSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          HStack { Image(systemName: symbol).font(.title3).foregroundStyle(pine); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
          texts
        }
      } else {
        HStack(spacing: 12) {
          Image(systemName: symbol).font(.title3).foregroundStyle(pine).frame(width: 28)
          texts
          Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
      }
    }.frame(minHeight: 36).contentShape(Rectangle())
  }
  private var texts: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
      Text(subtitle).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct HubHealthTiles: View {
  @Environment(\.dynamicTypeSize) private var textSize
  let model: HubModel, screen: HealthScreenModel
  private var sleep: Double? {
    model.autoSleepDeliveries.filter { $0.targetDate == screen.date && $0.dictionary == .timeAsleep }.max { $0.receivedAt < $1.receivedAt }?.normalization.record?.actualSleepSeconds ?? screen.currentSleep?.seconds
  }
  private var sleepText: String { guard let sleep else { return "—" }; let minutes=Int(sleep/60); return "\(minutes/60)時間\(minutes%60)分" }
  var body: some View {
    // 最大級の文字では1列にして、「7時間32分」などが切れないようにする（10/4）。
    LazyVGrid(columns: textSize.isAccessibilitySize ? [.init(.flexible())] : [.init(.flexible()),.init(.flexible())], spacing: 10) {
      NavigationLink { HealthWeightPage(screen:screen).toolbar(.visible, for:.navigationBar) } label: { tile("最新体重", value: screen.latestWeight?.value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", unit:"kg", symbol:"scalemass.fill", color:pine, note: weightNote, stale: weightStale) }.accessibilityIdentifier("health-weight-link")
      detailLink { tile("睡眠", value:sleepText, unit:"", symbol:"moon.fill", color:.gray) }
      detailLink { tile("歩数", value:foodNumber(screen.dailyStatistics[.stepCount]?.value), unit:"歩", symbol:"shoeprints.fill", color:pine) }
      detailLink { tile("活動", value:foodNumber(screen.dailyStatistics[.activeEnergyBurned]?.value), unit:"kcal", symbol:"flame.fill", color:.orange) }
    }.buttonStyle(.plain)
  }
  private func detailLink<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    NavigationLink { HealthDetailPage(screen:screen, autoSleep:model.autoSleepDeliveries, readEnabled:model.healthReadEnabled, readPrepared:model.healthReadPrepared, connect:{await model.connectHealth()},refresh:{await model.catchUpHealth()}).toolbar(.visible,for:.navigationBar) } label: { content() }
  }
  // 体重は測った時刻を添える。今日の値でなければ薄く表示し、古い値を今日の値と誤認させない（DESIGN 2.3、10/4）。
  private var weightStale: Bool { screen.latestWeight.map { HealthDates.local($0.start) != screen.date } ?? false }
  private var weightNote: String? {
    guard let sample = screen.latestWeight else { return nil }
    let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.timeZone = HealthDates.calendar.timeZone
    if !weightStale { f.dateFormat = "H:mm"; return (HealthDates.calendar.component(.hour, from: sample.start) < 12 ? "今朝 " : "今日 ") + f.string(from: sample.start) }
    let days = HealthDates.calendar.dateComponents([.day], from: HealthDates.calendar.startOfDay(for: sample.start), to: FoodDates.date(screen.date)).day ?? 0
    f.dateFormat = "M/d"; return "\(f.string(from: sample.start))（\(days)日前）"
  }
  private func tile(_ title: String, value: String, unit: String, symbol: String, color: Color, note: String? = nil, stale: Bool = false) -> some View {
    Group {
      if textSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          HStack { Image(systemName: symbol).foregroundStyle(color); Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
          tileText(title, value: value, unit: unit, note: note, stale: stale)
        }
      } else {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: symbol).foregroundStyle(color)
          tileText(title, value: value, unit: unit, note: note, stale: stale)
          Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(HubPalette.card, in: RoundedRectangle(cornerRadius: 14))
  }
  private func tileText(_ title: String, value: String, unit: String, note: String?, stale: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      MockFigure(value: value, unit: unit, size: 21).opacity(stale ? 0.55 : 1)
      Text(note ?? " ").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(note == nil)
    }
  }
}


struct HubMockTabBar: View {
  static let reservedHeight: CGFloat = 54
  @Binding var selection: String
  var onReselect: ((String) -> Void)? = nil
  private let tabs = [("home","ホーム","house"),("food","食事","fork.knife"),("other","その他","ellipsis")]
  var body: some View {
    VStack(spacing:0) {
      Rectangle().fill(pine.opacity(0.08)).frame(height:0.5)
      HStack(spacing:0) {
        ForEach(tabs, id: \.0) { key,title,symbol in
          Button {
            Haptics.emit(.selection)
            if selection == key { onReselect?(key) } else { selection=key }
          } label: {
            VStack(spacing:4) { Image(systemName:key == "home" && selection == key ? "house.fill" : symbol).font(.system(size:21)); Text(title).font(.system(size:10,weight:selection == key ? .semibold : .regular)) }
              .foregroundStyle(selection == key ? pine : Color.secondary).frame(maxWidth:.infinity,minHeight:48)
              .contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier("hub-tab-"+key).accessibilityAddTraits(selection == key ? .isSelected : [])
        }
      }.padding(.horizontal,18).padding(.top,5)
    }.background(HubPalette.tab.ignoresSafeArea(edges:.bottom))
  }
}

struct HubUnknownNutrientsHelp: View {
  @State private var open = false
  var body: some View {
    Button { open=true } label: { Label("栄養値が不明な食品を含みます", systemImage:"info.circle") }.frame(minHeight:32).font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain)
      .accessibilityIdentifier("nutrition-unknown-help")
      .popover(isPresented:$open) {
        VStack(alignment:.leading,spacing:12) {
          Text("栄養値がわからない食品を含みます。数字は、わかっている分の合計です。不明な値を0として保存しません。").font(.subheadline)
          Button("閉じる") { open=false }.accessibilityLabel("不明な値の説明を閉じる")
        }.padding(20).frame(maxWidth:280).foregroundStyle(.primary).presentationCompactAdaptation(.popover)
      }
  }
}
struct HubMealMacroLine: View {
  let items: [FoodItemSnapshot]
  var body: some View {
    let total=FoodTotal(items:items)
    HStack(spacing:12) {
      Text("P " + foodNumber(items.allSatisfy { $0.nutrients.protein == nil } ? nil : total.known[.protein])).foregroundStyle(pfcProtein)
      Text("F " + foodNumber(items.allSatisfy { $0.nutrients.fat == nil } ? nil : total.known[.fat])).foregroundStyle(pfcFat)
      Text("C " + foodNumber(items.allSatisfy { $0.nutrients.carbohydrate == nil } ? nil : total.known[.carbohydrate])).foregroundStyle(pfcCarb)
      if total.missing.values.contains(where: { $0 > 0 }) { HubUnknownNutrientsHelp() }
    }.font(.caption).lineLimit(1).minimumScaleFactor(0.7)
  }
}

func hubFoodEnergy(_ items: [FoodItemSnapshot]) -> String {
  guard !items.isEmpty else { return "0" }
  return items.allSatisfy { $0.nutrients.kcal == nil } ? "—" : foodNumber(FoodTotal(items:items).known[.kcal])
}
