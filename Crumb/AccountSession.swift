import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

struct SupabaseConfiguration {
    let url: URL
    let publishableKey: String
    static var current: Self? {
        guard let rawURL = Bundle.main.object(forInfoDictionaryKey: "CrumbSupabaseURL") as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host?.hasSuffix(".supabase.co") == true,
              let key = Bundle.main.object(forInfoDictionaryKey: "CrumbSupabaseKey") as? String,
              isPublicKey(key) else { return nil }
        return Self(url: url, publishableKey: key)
    }
    static func isPublicKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_publishable_") { return key.count > 25 }
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return false }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["role"] as? String == "anon"
    }
}

struct AccountSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: UUID
    var email: String?
    var appleUserID: String
    var displayName: String?
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Double
    let expires_at: Double?
    let user: User
    struct User: Decodable {
        let id: UUID
        let email: String?
        let user_metadata: Metadata?
    }
    struct Metadata: Decodable { let full_name: String? }
    func session(appleID: String, name: String?) -> AccountSession {
        AccountSession(accessToken: access_token, refreshToken: refresh_token,
                       expiresAt: expires_at.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(expires_in),
                       userID: user.id, email: user.email, appleUserID: appleID,
                       displayName: name ?? user.user_metadata?.full_name)
    }
}

enum AccountError: LocalizedError {
    case notConfigured, authorization, request, storage, unavailable, expired
    var errorDescription: String? {
        let key: String
        switch self {
        case .notConfigured: key = "Appleログインは現在準備中です。ログインせずに使えます。"
        case .authorization: key = "Appleでの本人確認ができませんでした。もう一度お試しください。"
        case .request: key = "接続できませんでした。通信状態を確認して、もう一度お試しください。"
        case .storage: key = "ログイン情報を安全に保存できませんでした。もう一度お試しください。"
        case .unavailable: key = "アカウントを削除できませんでした。時間をおいて再度お試しください。"
        case .expired: key = "もう一度Appleでログインしてください。"
        }
        return AppLanguage.text(key)
    }
}

// Session tokens stay in Keychain, never UserDefaults, app logs, or recipe records.
private enum SessionKeychain {
    static let service = (Bundle.main.bundleIdentifier ?? "crumb") + ".account"
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "supabase-session"]
    }
    static func load() throws -> AccountSession? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccountError.storage }
        return try JSONDecoder().decode(AccountSession.self, from: data)
    }
    static func save(_ session: AccountSession) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw AccountError.storage }
        } else if status != errSecSuccess { throw AccountError.storage }
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.storage }
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var session: AccountSession?
    @Published private(set) var restoring = true
    @Published private(set) var busy = false
    @Published var error: String?
    private var nonce: String?
    var configured: Bool { SupabaseConfiguration.current != nil }
    var scope: String { session?.userID.uuidString.lowercased() ?? "guest" }
    var signedIn: Bool { session != nil }

    func prepareApple(_ request: ASAuthorizationAppleIDRequest) {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            nonce = nil; error = AccountError.authorization.localizedDescription; return
        }
        let raw = bytes.map { String(format: "%02x", $0) }.joined()
        nonce = raw
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func signIn(_ result: Result<ASAuthorization, Error>) async {
        guard !busy else { return }
        do {
            let credential = try appleCredential(result)
            guard let nonce else { throw AccountError.authorization }
            self.nonce = nil
            busy = true
            defer { busy = false }
            guard let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else { throw AccountError.authorization }
            let data = try await call("auth/v1/token?grant_type=id_token", body: ["provider": "apple", "id_token": token, "nonce": nonce])
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            let next = response.session(appleID: credential.user, name: name)
            try SessionKeychain.save(next)
            session = next
        } catch {
            if (error as? ASAuthorizationError)?.code != .canceled { self.error = (error as? AccountError ?? .authorization).localizedDescription }
        }
    }

    func restore() async {
        defer { restoring = false }
        do {
            guard let saved = try SessionKeychain.load() else { return }
            let state: ASAuthorizationAppleIDProvider.CredentialState
            do { state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: saved.appleUserID) }
            catch {
                // Offline checks may keep cached local data accessible; a known revocation never does.
                session = saved
                return
            }
            guard state == .authorized else {
                try? SessionKeychain.clear()
                session = nil
                return
            }
            session = saved
            if saved.expiresAt <= Date().addingTimeInterval(60) { _ = try? await validSession() }
        } catch { session = nil }
    }

    func validSession() async throws -> AccountSession {
        guard let saved = session else { throw AccountError.expired }
        if saved.expiresAt > Date().addingTimeInterval(60) { return saved }
        let data = try await call("auth/v1/token?grant_type=refresh_token", body: ["refresh_token": saved.refreshToken])
        let next = try JSONDecoder().decode(TokenResponse.self, from: data).session(appleID: saved.appleUserID, name: saved.displayName)
        try SessionKeychain.save(next)
        session = next
        return next
    }

    func signOut() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if let saved = session {
                _ = try? await call("auth/v1/logout?scope=local", token: saved.accessToken)
            }
            try SessionKeychain.clear()
            session = nil
        } catch { self.error = AccountError.storage.localizedDescription }
    }

    // The server verifies the reauthenticated Apple identity and revokes Apple tokens before deleting data.
    func deleteAccount(_ result: Result<ASAuthorization, Error>, removeLocalData: () throws -> Void) async -> Bool {
        guard !busy else { return false }
        do {
            let credential = try appleCredential(result)
            guard let nonce, credential.user == session?.appleUserID,
                  let tokenData = credential.identityToken, let idToken = String(data: tokenData, encoding: .utf8),
                  let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8) else { throw AccountError.authorization }
            self.nonce = nil
            busy = true
            defer { busy = false }
            let saved = try await validSession()
            _ = try await call("functions/v1/delete-account", body: ["authorizationCode": code, "idToken": idToken, "nonce": nonce], token: saved.accessToken)
            try removeLocalData()
            try SessionKeychain.clear()
            session = nil
            return true
        } catch {
            if (error as? ASAuthorizationError)?.code != .canceled { self.error = AccountError.unavailable.localizedDescription }
            return false
        }
    }

    func credentialsRevoked() {
        do { try SessionKeychain.clear(); session = nil }
        catch { self.error = AccountError.storage.localizedDescription }
    }

    private func appleCredential(_ result: Result<ASAuthorization, Error>) throws -> ASAuthorizationAppleIDCredential {
        let result = try result.get()
        guard let credential = result.credential as? ASAuthorizationAppleIDCredential else { throw AccountError.authorization }
        return credential
    }

    private func call(_ path: String, body: [String: String]? = nil, token: String? = nil) async throws -> Data {
        guard let config = SupabaseConfiguration.current,
              let url = URL(string: path, relativeTo: config.url.appendingPathComponent("/")) else { throw AccountError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw AccountError.request }
        return data
    }
}
