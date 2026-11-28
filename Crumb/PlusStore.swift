import SwiftUI
import StoreKit

@MainActor
final class PlusStore: ObservableObject {
    static let monthlyID = "app.tabinote.meals.plus.monthly"
    static let yearlyID = "app.tabinote.meals.plus.yearly"
    static let productIDs = [monthlyID, yearlyID]
    static func policyURL(_ key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    static var purchasesEnabled: Bool {
        #if CRUMB_STOREKIT_LOCAL
        return true
        #else
        return CloudLibrary.enabled && policyURL("CrumbPrivacyURL") != nil && policyURL("CrumbTermsURL") != nil
        #endif
    }
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published private(set) var hasPlus = false
    @Published private(set) var localTesting = false
    @Published private(set) var expiresAt: Date?
    @Published var message: String?
    private var account: AccountStore?
    private var userID: UUID?
    private var updates: Task<Void, Never>?
    private var reconcileVersion = 0
    private var refreshTask: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result,
                   Self.productIDs.contains(transaction.productID) {
                    await self.reconcile()
                    // Finish only after current entitlements have been reconciled with the server.
                    if self.hasPlus || transaction.revocationDate != nil || (transaction.expirationDate ?? .distantFuture) < Date() {
                        await transaction.finish()
                    }
                }
            }
        }
    }
    deinit { updates?.cancel(); refreshTask?.cancel() }

    func configure(account: AccountStore) async {
        self.account = account
        userID = account.session?.userID
        hasPlus = false; localTesting = false; expiresAt = nil
        async let loaded: () = loadProducts()
        await reconcile()
        await loaded
    }
    func loadProducts() async {
        do {
            products = try await Product.products(for: Self.productIDs)
                .filter { $0.type == .autoRenewable }
                .sorted { $0.id == Self.yearlyID && $1.id != Self.yearlyID }
        } catch { message = AppLanguage.text("料金を取得できませんでした。もう一度お試しください。") }
    }
    func purchase(_ product: Product) async {
        guard !busy else { return }
        #if !CRUMB_STOREKIT_LOCAL
        guard Self.purchasesEnabled else { message = AppLanguage.text("購入はまだ利用できません。"); return }
        #endif
        // Purchases are bound to the Crumb account, not an editable preferences flag.
        guard let token = purchaseToken else {
            message = AppLanguage.text("購入前にAppleでログインしてください。")
            return
        }
        busy = true; defer { busy = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(token)]) {
            case .success(let result):
                guard case .verified(let transaction) = result else { throw CloudError(status: 0) }
                await reconcile()
                if hasPlus { await transaction.finish() }
            case .pending: message = AppLanguage.text("購入の承認を待っています。承認後に自動で反映されます。")
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = AppLanguage.text("購入を完了できませんでした。もう一度お試しください。") }
    }
    func restore() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await AppStore.sync()
            await reconcile()
            if !hasPlus { message = AppLanguage.text("このアカウントの有効な購入が見つかりませんでした。") }
        } catch { message = AppLanguage.text("購入を復元できませんでした。もう一度お試しください。") }
    }
    func reconcile() async {
        reconcileVersion += 1
        let version = reconcileVersion
        let expectedUser = userID
        var latest: Date?
        var isLocal = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil, !transaction.isUpgraded,
                  let expiration = transaction.expirationDate, expiration > Date(),
                  transaction.appAccountToken == purchaseToken else { continue }
            #if DEBUG
            if transaction.environment == .xcode {
                latest = max(latest ?? .distantPast, expiration)
                isLocal = true
                continue
            }
            #endif
            guard let account, let expectedUser else { continue }
            do {
                struct Receipt: Encodable { let signedTransaction: String }
                struct Access: Decodable { let active: Bool; let expires_at: Double? }
                let api = SupabaseREST(account: account, userID: expectedUser)
                let data = try await api.request("functions/v1/verify-entitlement", method: "POST",
                                                 data: JSONEncoder().encode(Receipt(signedTransaction: result.jwsRepresentation)))
                let access = try JSONDecoder().decode(Access.self, from: data)
                if access.active, let seconds = access.expires_at {
                    latest = max(latest ?? .distantPast, Date(timeIntervalSince1970: seconds))
                }
            } catch { message = AppLanguage.text("購入を確認中です。通信状態を確認して、購入を復元してください。") }
        }
        // Server state can include a signed renewal, grace period, or an explicit beta grant.
        if !isLocal, CloudLibrary.enabled, let account, let expectedUser {
            do {
                struct Access: Decodable { let active: Bool; let expires_at: Double? }
                let access = try await SupabaseREST(account: account, userID: expectedUser).rpc("crumb_my_plan", as: Access.self)
                if access.active, let seconds = access.expires_at { latest = Date(timeIntervalSince1970: seconds) }
                else { latest = nil }
            } catch {
                // Do not invent an entitlement from network failure.
                latest = nil
            }
        }
        guard userID == expectedUser, version == reconcileVersion else { return }
        expiresAt = latest
        localTesting = isLocal
        hasPlus = (latest ?? .distantPast) > Date()
        refreshTask?.cancel()
        if let latest {
            refreshTask = Task { [weak self] in
                let delay = max(1, min(3600, latest.timeIntervalSinceNow))
                try? await Task.sleep(for: .seconds(delay))
                if !Task.isCancelled { await self?.reconcile() }
            }
        }
    }
    var purchaseToken: UUID? {
        if let userID { return userID }
        #if CRUMB_STOREKIT_LOCAL
        // Only a StoreKit-configured debug run can complete this local purchase. Its JWS is rejected by the cloud verifier.
        let key = "crumb.storekit.localAccount"
        if let value = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: value) { return uuid }
        let value = UUID(); UserDefaults.standard.set(value.uuidString, forKey: key); return value
        #else
        return nil
        #endif
    }
}
