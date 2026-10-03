import Foundation
public enum HubScriptResponse {
    public static func decode<R: Decodable>(_ type: R.Type, from data: Data) throws -> R {
        let value: Envelope<R>
        do { value = try JSONDecoder().decode(Envelope<R>.self, from: data) } catch { throw HubError.invalidResponse }
        guard !(value.error != nil && value.response != nil) else { throw HubError.invalidResponse }
        if let error = value.error {
            let raw = error.details?.first?.errorMessage ?? "SCRIPT_EXECUTION_ERROR"
            // GASのError文字列の既知の接頭辞だけを外す。追加本文を含む未知の値は拒否する。
            let code = raw.hasPrefix("Error: ") ? String(raw.dropFirst(7)) : raw
            if ["BUSY", "STORAGE_UNAVAILABLE", "SNAPSHOT_CHANGED", "CURSOR_EXPIRED"].contains(code) { throw HubError.remote(code) }
            if ["OWNER_REQUIRED", "ACCOUNT_NOT_CONFIGURED"].contains(code) { throw HubError.authentication }
            throw HubError.invalidResponse
        }
        guard value.done == true, let response = value.response else { throw HubError.remote("EXECUTION_PENDING") }
        return response.result
    }
    private struct Envelope<R: Decodable>: Decodable { var done: Bool?; var error: Failure?; var response: Response<R>? }
    private struct Response<R: Decodable>: Decodable { var result: R }
    private struct Failure: Decodable { var details: [Detail]? }
    private struct Detail: Decodable { var errorMessage: String? }
}
