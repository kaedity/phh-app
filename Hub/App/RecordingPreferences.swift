import PHHHubCore
import SwiftUI

enum RecordingPreferences {
    static var defaults: UserDefaults {
        let preview = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--p") && $0.hasSuffix("-preview") }
        return preview ? UserDefaults(suiteName: "jp.personalhealthhub.recording.synthetic")! : .standard
    }
    static var cutoffMinutes: Int {
        get { defaults.object(forKey: "food-day-cutoff-minutes") as? Int ?? 240 }
        set { guard (0..<1440).contains(newValue) else { return }; defaults.set(newValue, forKey: "food-day-cutoff-minutes") }
    }
    static func day(at instant: Date = .now) -> Date {
        let policy = (try? RecordingDayPolicy(cutoffMinutes: cutoffMinutes)) ?? (try! RecordingDayPolicy())
        return FoodDates.date(try! policy.recordingDay(at: instant))
    }
}

struct RecordingPreferencesPage: View {
    @State private var cutoff: Date
    init() {
        _cutoff = State(initialValue: FoodDates.calendar.date(byAdding: .minute, value: RecordingPreferences.cutoffMinutes, to: FoodDates.date("2000-01-01"))!)
    }
    var body: some View {
        Form {
            Section("深夜の食事の日付") {
                DatePicker("前日とする時刻の境界", selection: $cutoff, displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, FoodDates.calendar.timeZone)
                    .accessibilityIdentifier("food-cutoff")
                Text("この時刻より前の食事は、前日の日付から入力を始めます。食事画面で選んだ日付や、会話で明示した日付を優先します。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("保存済みの記録の日付は変更しません。時刻は日本時間です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("食事の記録設定")
            .onChange(of: cutoff) { _, value in
                let clock = FoodDates.calendar.dateComponents([.hour, .minute], from: value)
                RecordingPreferences.cutoffMinutes = clock.hour! * 60 + clock.minute!
            }
    }
}
