import XCTest
import StoreKit
import StoreKitTest
@testable import crumb

@MainActor
final class SubscriptionTests: XCTestCase {
    func testPurchaseRestoreExpirationRefundAndWrongAccount() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Crumb", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        if !session.allTransactions().isEmpty {
            throw XCTSkip("StoreKitTest could not clear its test state (SKInternalErrorDomain code 3 on iOS 26.5). Run on a fixed runtime; manual purchase is verified separately.")
        }
        let store = PlusStore()
        await store.configure(account: AccountStore())
        if store.hasPlus { throw XCTSkip("StoreKitTest failed to reset previous entitlements on this runtime.") }
        XCTAssertEqual(Set(store.products.map(\.id)), Set(PlusStore.productIDs))
        let token = try XCTUnwrap(store.purchaseToken)
        do {
            _ = try await session.buyProduct(identifier: PlusStore.monthlyID, options: [.appAccountToken(token)])
        } catch StoreKitError.notEntitled {
            throw XCTSkip("StoreKitTest runtime rejected the test mutation. This is not a passing purchase test.")
        }
        await store.reconcile()
        XCTAssertTrue(store.hasPlus)
        XCTAssertTrue(store.localTesting)
        await store.restore()
        XCTAssertTrue(store.hasPlus, "Restore must keep the valid entitlement")
        try session.expireSubscription(productIdentifier: PlusStore.monthlyID)
        await store.reconcile()
        XCTAssertFalse(store.hasPlus)
        let yearly = try await session.buyProduct(identifier: PlusStore.yearlyID, options: [.appAccountToken(token)])
        await store.reconcile()
        XCTAssertTrue(store.hasPlus)
        try session.refundTransaction(identifier: UInt(yearly.id))
        await store.reconcile()
        XCTAssertFalse(store.hasPlus)
        _ = try await session.buyProduct(identifier: PlusStore.monthlyID, options: [.appAccountToken(UUID())])
        await store.reconcile()
        XCTAssertFalse(store.hasPlus, "Another account's purchase must not grant access")
    }

    func testPolicyKeepsFreeNotebookAndInvitedParticipation() {
        let viewer = UUID(), owner = UUID()
        let extra = MenuBook(id: "extra", name: "Dinner")
        XCTAssertTrue(PlanPolicy.canEdit(book: .defaultBook, viewer: viewer, plus: false))
        XCTAssertFalse(PlanPolicy.canEdit(book: extra, viewer: viewer, plus: false))
        XCTAssertTrue(PlanPolicy.canEdit(book: extra, viewer: viewer, plus: true))
        var invited = MenuBook(id: "shared", name: "Family", ownerID: owner, ownerHasPlus: true)
        XCTAssertTrue(PlanPolicy.canEdit(book: invited, viewer: viewer, plus: false))
        XCTAssertFalse(PlanPolicy.canInvite(book: invited, viewer: viewer, plus: true))
        invited.ownerHasPlus = false
        XCTAssertFalse(PlanPolicy.canEdit(book: invited, viewer: viewer, plus: true))
        XCTAssertFalse(PlanPolicy.canInvite(book: .defaultBook, viewer: nil, plus: true))
    }
}
