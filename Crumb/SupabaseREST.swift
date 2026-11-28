import Foundation

struct CloudError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401: return AppLanguage.text("もう一度Appleでログインしてください。")
        case 402, 403: return AppLanguage.text("この操作にはブック所有者の有効なPlusが必要です。")
        case 409: return AppLanguage.text("別の端末で変更されています。両方の変更を残して再同期します。")
        case 404: return AppLanguage.text("共有ブックまたは招待が見つかりません。")
        default: return AppLanguage.text("同期できませんでした。端末の記録は保持しています。")
        }
    }
}

@MainActor
struct SupabaseREST {
    let account: AccountStore
    let userID: UUID
    func request(_ path: String, method: String = "GET", data: Data? = nil,
                 mime: String = "application/json", extra: [String: String] = [:]) async throws -> Data {
        guard let config = SupabaseConfiguration.current,
              let url = URL(string: path, relativeTo: config.url.appendingPathComponent("/")) else { throw AccountError.notConfigured }
        let session = try await account.validSession()
        guard session.userID == userID else { throw CancellationError() }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = data; request.timeoutInterval = 45
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        for (key, value) in extra { request.setValue(value, forHTTPHeaderField: key) }
        let (body, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard account.session?.userID == userID else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw CloudError(status: 0) }
        guard (200..<300).contains(response.statusCode) else { throw CloudError(status: response.statusCode) }
        return body
    }
    func rpc<T: Encodable, R: Decodable>(_ name: String, _ parameters: T, as: R.Type) async throws -> R {
        let bytes = try await request("rest/v1/rpc/\(name)", method: "POST", data: JSONEncoder().encode(parameters))
        return try JSONDecoder().decode(R.self, from: bytes.isEmpty ? Data("null".utf8) : bytes)
    }
    func rpc<R: Decodable>(_ name: String, as: R.Type) async throws -> R {
        try await rpc(name, [String: String](), as: R.self)
    }
}
