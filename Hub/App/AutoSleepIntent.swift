import AppIntents
import Foundation
import PHHHubCore

enum AutoSleepDictionaryChoice: String, AppEnum {
    case timeAsleep, sleepRings, readiness
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "AutoSleep辞書の種類"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.timeAsleep:"睡眠時間", .sleepRings:"睡眠リング", .readiness:"準備状態"]
}
struct ReceiveAutoSleepIntent: AppIntent {
    static let title: LocalizedStringResource = "AutoSleepの辞書を受け取る"
    static let description = IntentDescription("AutoSleepの辞書を端末に保存します。Appleの睡眠段階への変換や外部送信は行いません。")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "辞書の種類", default: .timeAsleep) var kind: AutoSleepDictionaryChoice
    @Parameter(title: "AutoSleep辞書（JSON）") var json: String
    @Parameter(title: "対象日（YYYY-MM-DD）") var targetDate: String
    @Parameter(title: "各項目の単位（JSON）", default: "{}") var unitsJSON: String
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Hub/AutoSleep", isDirectory: true)
        let delivery = try AutoSleepIntake.delivery(dictionary: AutoSleepDictionary(rawValue: kind.rawValue)!, targetDate: targetDate,
            timeZoneID: "Asia/Tokyo", json: json, unitsJSON: unitsJSON, receivedAt: .now)
        let stored = try AutoSleepInbox(url: directory.appendingPathComponent("intake.json")).receive(delivery)
        if stored.normalization.record == nil { return .result(dialog: "原辞書を端末に保存しました。内容の確認が必要な項目があります。") }
        return .result(dialog: "端末に保存しました。単位が未確認の項目は採用値にしていません。")
    }
}
struct PHHShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReceiveAutoSleepIntent(), phrases: ["\(.applicationName)にAutoSleepを渡す"], shortTitle: "AutoSleepを取り込む", systemImageName: "moon.zzz")
    }
}
