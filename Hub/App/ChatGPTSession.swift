import AuthenticationServices
import Foundation
import Network
import Observation
import PHHHubCore
import Security
import UIKit

/// P2は本人のChatGPTログインだけを引き継ぐ。解析と実写真送信はP4で追加する。
/// ログインは、アプリ内で 127.0.0.1:1455 を待ち受け、ASWebAuthenticationSession のログイン画面からの戻りを受け取る。
@MainActor @Observable final class ChatGPTSession {
    private(set) var credential: ChatGPTPlan.Credential?
    private(set) var busy = false
    var message = "ChatGPTに未接続"
    private var authSession: ASWebAuthenticationSession?
    private let presenter = Presenter()
    private let offline: Bool

    init(offline: Bool = false) {
        self.offline = offline
        guard !offline else { message = "合成表示 · 認証と解析送信は無効"; return }
        credential = CredentialStore.load()
        if let credential { message = credential.planAllowed ? "ChatGPTに接続済み" : "ChatGPTプランの利用が未許可です" }
    }
    var signedIn: Bool { credential?.accessToken != nil && credential?.planAllowed == true }

    func signIn() async {
        guard !busy, !offline else { return }
        busy = true; defer { busy = false }
        let listener = LoopbackCallback()
        do {
            try await listener.start()
            let state = ChatGPTPlan.randomToken(), nonce = ChatGPTPlan.randomToken(), verifier = ChatGPTPlan.randomToken(48)
            let saved = CredentialStore.load()
            let url = ChatGPTPlan.authorizationURL(savedClientID: saved?.clientID, idTokenHint: saved?.idToken, hostID: HostID.value,
                                                   state: state, nonce: nonce, verifier: verifier)
            message = "ログイン画面でChatGPTにログインし、許可してください"
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "phh-siwc-unused") { _, _ in
                // 戻りは127.0.0.1の待ち受けで受け取る。ここに来るのは、閉じた・取り消したときだけ。
                listener.cancel()
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            guard session.start() else { throw ChatGPTPlan.Failure.denied("ログイン画面を開けません") }
            let query = try await listener.waitForCallback()
            session.cancel(); authSession = nil
            let accepted = try ChatGPTPlan.acceptCallback(query, expectedState: state, savedClientID: saved?.clientID)
            if saved == nil { CredentialStore.save(.init(clientID: accepted.clientID)) }  // 交換に失敗しても同じ登録を使えるように
            message = "ログインを確認しています"
            let tokens: ChatGPTPlan.TokenResponse = try await postForm(ChatGPTPlan.tokenURL, [
                "grant_type": "authorization_code", "client_id": accepted.clientID, "code": accepted.code,
                "code_verifier": verifier, "redirect_uri": ChatGPTPlan.redirectURI, "resource": ChatGPTPlan.resource,
            ])
            guard let idToken = tokens.id_token else { throw ChatGPTPlan.Failure.invalidToken("IDトークンなし") }
            let claims = try ChatGPTPlan.validateIDToken(idToken, clientID: accepted.clientID, nonce: nonce, jwks: try await fetchJWKS())
            if let previous = saved?.subject, previous != claims.subject { throw ChatGPTPlan.Failure.invalidToken("前回と違うアカウント") }
            let scopes = (tokens.scope ?? "").split(separator: " ").map(String.init)
            let record = ChatGPTPlan.Credential(clientID: accepted.clientID, subject: claims.subject, email: claims.email, idToken: idToken,
                                                accessToken: tokens.access_token, refreshToken: tokens.refresh_token,
                                                expiresAt: Date().addingTimeInterval(Double(tokens.expires_in ?? 3600)), scopes: scopes)
            CredentialStore.save(record); credential = record
            message = record.planAllowed ? "ChatGPTに接続済み" : ChatGPTPlan.Failure.planNotAllowed.localizedDescription
        } catch {
            listener.cancel(); authSession?.cancel(); authSession = nil
            message = (error as? LocalizedError)?.errorDescription ?? "ログインできませんでした（\(error.localizedDescription)）"
        }
    }

    /// 更新トークンで新しいアクセストークンを取れるかを、1時間待たずに確かめる（M-3の完了判定）。
    func refreshNow() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { _ = try await validAccessToken(force: true); message = "ログインを更新しました（有効期限 \(credential?.expiresAt?.formatted(date: .omitted, time: .shortened) ?? "-")）" }
        catch { message = (error as? LocalizedError)?.errorDescription ?? "更新できませんでした（\(error.localizedDescription)）" }
    }

    /// 本番採用済みの契約を再利用。実入力を送信する操作はP4-6の本人判断後に接続します。
    func analyzeFood(jpeg:Data?,note:String,model:String="gpt-5.6-sol") async throws -> FoodDraft {
        try await analyzeFood(jpegs:jpeg.map{[$0]} ?? [],note:note,model:model)
    }
    func analyzeFood(jpegs:[Data],note:String,model:String="gpt-5.6-sol") async throws -> FoodDraft {
        guard !offline, !busy, !jpegs.isEmpty || !note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, note.count<=8000 else {throw FoodFailure.invalidValue}
        let batch=try FoodPhotoBatch(jpegs)
        busy=true;defer{busy=false}
        let token=try await validAccessToken()
        var request=URLRequest(url:ChatGPTPlan.responsesURL);request.httpMethod="POST";request.timeoutInterval=120
        request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("text/event-stream",forHTTPHeaderField:"Accept")
        request.httpBody=ChatGPTPlan.analysisBody(model:model,jpegs:batch.jpegs,note:note)
        let (bytes,response)=try await URLSession.shared.bytes(for:request)
        guard (response as? HTTPURLResponse)?.statusCode==200 else {throw ChatGPTPlan.Failure.denied("解析の接続を確認してください。")}
        var reader=ChatGPTPlan.StreamReader()
        for try await line in bytes.lines {try Task.checkCancellation();reader.feed(line);if reader.finished{break}}
        let estimate=try reader.estimate()
        return try FoodDraft.fromAnalysisJSON(JSONEncoder().encode(estimate))
    }

    /// P8-3の2枚契約。本人の実入力送信承認まではUIから接続しません。
    func analyzeSharedPlate(before: Data, after: Data?, note: String, model: String = "gpt-5.6-sol") async throws -> SharedPlateEstimate {
        guard !offline, !busy else { throw FoodFailure.pendingEdit }
        let body = try SharedPlateRequest.body(model: model, before: before, after: after, note: note)
        busy = true; defer { busy = false }
        let token = try await validAccessToken()
        var request = URLRequest(url: ChatGPTPlan.responsesURL); request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTPlan.Failure.denied("解析の接続を確認してください。") }
        var reader = ChatGPTPlan.StreamReader()
        for try await line in bytes.lines { try Task.checkCancellation(); reader.feed(line); if reader.finished { break } }
        if let failure = reader.failure { throw ChatGPTPlan.Failure.stream(failure) }
        guard reader.completed else { throw ChatGPTPlan.Failure.stream("途中で切れた") }
        return try SharedPlateEstimate.decode(Data(reader.text.utf8))
    }

    private func validAccessToken(force: Bool = false) async throws -> String {
        guard var saved = credential, saved.planAllowed, let refresh = saved.refreshToken else { throw ChatGPTPlan.Failure.planNotAllowed }
        if force || saved.needsRefresh() {
            message = "ログインを更新しています"
            let tokens: ChatGPTPlan.TokenResponse = try await postForm(ChatGPTPlan.tokenURL, [
                "grant_type": "refresh_token", "client_id": saved.clientID, "refresh_token": refresh, "resource": ChatGPTPlan.resource,
            ])
            saved.accessToken = tokens.access_token
            saved.refreshToken = tokens.refresh_token ?? refresh
            saved.expiresAt = Date().addingTimeInterval(Double(tokens.expires_in ?? 3600))
            if let scope = tokens.scope { saved.scopes = scope.split(separator: " ").map(String.init) }
            CredentialStore.save(saved); credential = saved
        }
        guard let token = saved.accessToken else { throw ChatGPTPlan.Failure.planNotAllowed }
        return token
    }

    private func postForm<T: Decodable>(_ url: URL, _ fields: [String: String]) async throws -> T {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTPlan.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ChatGPTPlan.Failure.invalidToken("HTTP \(status)\(code.map { " " + $0 } ?? "")")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func fetchJWKS() async throws -> ChatGPTPlan.JWKS {
        let config = try JSONSerialization.jsonObject(with: try await URLSession.shared.data(from: ChatGPTPlan.configurationURL).0) as? [String: Any]
        guard let jwksURL = (config?["jwks_uri"] as? String).flatMap(URL.init(string:)) else { throw ChatGPTPlan.Failure.invalidToken("公開鍵の場所") }
        return try JSONDecoder().decode(ChatGPTPlan.JWKS.self, from: try await URLSession.shared.data(from: jwksURL).0)
    }
}

/// ログイン画面を出すウインドウ。
private final class Presenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}

/// 127.0.0.1:1455 でブラウザからの戻り（GET /auth/callback?...）を1回だけ受け取る。
private final class LoopbackCallback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jp.personalhealthhub.app.siwc.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var ready: CheckedContinuation<Void, Error>?
    private var callback: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ChatGPTPlan.port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.withLock { ready = c }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.lock.withLock { self.ready?.resume(); self.ready = nil }
                case .failed(let error): self.lock.withLock { self.ready?.resume(throwing: error); self.ready = nil }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
            lock.withLock {
                if let result { c.resume(with: result) } else { callback = c }
            }
        }
    }

    func cancel() { finish(.failure(ChatGPTPlan.Failure.denied("ログイン画面が閉じられました"))) }

    private func finish(_ value: Result<[String: String], Error>) {
        lock.withLock {
            guard result == nil else { return }
            result = value
            callback?.resume(with: value); callback = nil
            ready?.resume(throwing: CancellationError()); ready = nil
        }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.listener?.cancel() }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let firstLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let parsed = ChatGPTPlan.queryItems(fromRequestLine: firstLine)
            let isCallback = parsed?.path == "/auth/callback"
            let body = isCallback ? "ログインを受け取りました。アプリに戻ります。" : "Not found"
            let head = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback, let query = parsed?.query { self.finish(.success(query)) }
        }
    }
}

/// 認証情報はKeychainだけに置く（この端末だけ・初回のロック解除後に読める）。
private enum CredentialStore {
    static let service = "jp.personalhealthhub.app.siwc"
    static func load() -> ChatGPTPlan.Credential? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "credential", kSecReturnData: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ChatGPTPlan.Credential.self, from: data)
    }
    static func save(_ credential: ChatGPTPlan.Credential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "credential"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// この端末の ext_agent_host_id。秘密ではないが、端末ごとに一度だけ作って使い続ける。
private enum HostID {
    static var value: String {
        let key = "phh.siwc.hostID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let made = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(made, forKey: key)
        return made
    }
}
