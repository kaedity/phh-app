import Foundation
import UIKit
import GoogleSignIn
import Observation
import PHHHubCore
@MainActor @Observable final class GoogleTransport: HubTransport {
    private(set) var connected = false
    private(set) var authMessage = "Googleに未接続"
    #if DEBUG
    var debugOffline = UserDefaults.standard.bool(forKey: "phh.synthetic.offline") {
        didSet { UserDefaults.standard.set(debugOffline, forKey: "phh.synthetic.offline") }
    }
    var debugLoseNextReceipt = false
    var debugCorruptNextDelta = false
    var debugExpireNextCall = false
    #endif
    private let clientID: String, deploymentID: String, scopes: [String]
    let timing = SyncTimingRecorder()
    let ownerEmail: String
    private let environmentSafe: Bool
    var configured: Bool { !clientID.isEmpty && !deploymentID.isEmpty && environmentSafe && Set(scopes) == Set(["https://www.googleapis.com/auth/script.scriptapp", "https://www.googleapis.com/auth/script.send_mail", "https://www.googleapis.com/auth/drive", "https://www.googleapis.com/auth/spreadsheets", "https://www.googleapis.com/auth/userinfo.email"]) && !ownerEmail.isEmpty }
    init(offline: Bool = false) {
        if offline {
            clientID = ""; deploymentID = ""; scopes = []; ownerEmail = "synthetic@example.test"; environmentSafe = false
            authMessage = "合成表示 · 認証と通信は無効"; return
        }
        let c = Bundle.main.url(forResource: "Connection", withExtension: "plist").flatMap { NSDictionary(contentsOf: $0) } ?? [:]
        clientID = c["GoogleClientID"] as? String ?? ""; deploymentID = c["DeploymentID"] as? String ?? ""; scopes = c["Scopes"] as? [String] ?? []; ownerEmail = c["OwnerEmail"] as? String ?? ""
        environmentSafe = c["Environment"] as? String == hubEnvironment && c["RealDataEnabled"] is Bool
        if !clientID.isEmpty { GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID) }
        if !environmentSafe { authMessage = "環境設定を確認してください" }
    }
    private func accept(_ user: GIDGoogleUser) {
        connected = user.profile?.email.lowercased() == ownerEmail.lowercased() && Set(scopes).isSubset(of: Set(user.grantedScopes ?? []))
        authMessage = connected ? "Googleに接続済み" : "保管用アカウントとアクセス許可を確認してください"
    }
    func restore() async { guard configured else { return }; do { accept(try await GIDSignIn.sharedInstance.restorePreviousSignIn()) } catch { connected = false } }
    func signIn() async throws {
        guard configured else { throw HubError.configuration }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }), let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { throw HubError.authentication }
        var presenter = root; while let next = presenter.presentedViewController { presenter = next }
        accept(try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: ownerEmail, additionalScopes: scopes).user)
        guard connected else { throw HubError.authentication }
    }
    // submitHubOperationは同じロック内でID/内容ハッシュを先に照合する。
    // 保存済みなら元の結果を返し、保存処理を繰り返さない。
    func resolve(_ operation: HubOperation) async throws -> Receipt { try await submit(operation) }
    func syncDelta(_ query: HubQuery, date: String) async throws -> Delta {
        var page: Delta = try await call("syncHubChanges", query)
        #if DEBUG
        if debugCorruptNextDelta { debugCorruptNextDelta = false; page.environment = "PHH_TEST" }
        #endif
        return page
    }
    func result(_ operation: HubOperation) async throws -> Receipt { try await call("getHubOperationResult", HubQuery(operationID: operation.id)) }
    func submit(_ operation: HubOperation) async throws -> Receipt {
        try operation.validate()
        let receipt: Receipt = try await call("submitHubOperation", operation)
        try receipt.validate(for: operation)
        #if DEBUG
        if debugLoseNextReceipt && receipt.status == "committed" {
            debugLoseNextReceipt = false
            throw HubError.remote("応答消失の試験")
        }
        #endif
        return receipt
    }
    func processIntake(date: String) async throws {
        struct Poll: Decodable { var processed: Int; var publication_pending: Bool }
        let _: Poll = try await call("processHubIntake", HubQuery(date: date))
    }
    func delta(_ query: HubQuery) async throws -> Delta { try await call("getHubChanges", query) }
    private func call<T: Encodable, R: Decodable>(_ function: String, _ argument: T) async throws -> R {
        guard configured else { throw HubError.configuration }
        #if DEBUG
        if debugOffline { throw HubError.remote("オフライン試験") }
        if debugExpireNextCall {
            debugExpireNextCall = false; connected = false; authMessage = "認証切れの模擬試験・再接続してください"
            throw HubError.authentication
        }
        #endif
        guard connected, let current = GIDSignIn.sharedInstance.currentUser else { throw HubError.authentication }
        let user: GIDGoogleUser
        do {
            let token = timing.begin(.authentication); defer { timing.end(token) }
            user = try await current.refreshTokensIfNeeded()
        } catch { connected = false; throw HubError.authentication }
        accept(user); guard connected else { throw HubError.authentication }
        var request = URLRequest(url: URL(string: "https://script.googleapis.com/v1/scripts/\(deploymentID):run")!)
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("Bearer \(user.accessToken.tokenString)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try timing.measure(.requestEncoding) {
            try JSONSerialization.data(withJSONObject: ["function": function, "parameters": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(argument))], "devMode": false])
        }
        let data: Data, response: URLResponse
        do {
            let token = timing.begin(.http); var received = 0
            defer { timing.end(token, requestBytes: request.httpBody?.count ?? 0, responseBytes: received) }
            (data, response) = try await URLSession.shared.data(for: request); received = data.count
        }
        guard data.count <= 240000, let http = response as? HTTPURLResponse else { throw HubError.invalidResponse }
        if [401, 403].contains(http.statusCode) { connected = false; authMessage = "Googleへの再接続か設定の確認が必要です"; throw HubError.authentication }
        guard http.statusCode == 200 else { throw HubError.remote("HTTP_\(http.statusCode)") }
        return try timing.measure(.responseDecoding) { try HubScriptResponse.decode(R.self, from: data) }
    }
}
