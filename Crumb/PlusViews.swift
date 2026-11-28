import SwiftUI
import StoreKit

struct PlusView: View {
    @EnvironmentObject private var plus: PlusStore
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected = PlusStore.yearlyID
    @State private var signIn = false
    @State private var manage = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image("CrumbAvatar").resizable().scaledToFit().frame(width: 76, height: 76).accessibilityHidden(true)
                    Text("Crumb Plus").font(.custom("Nunito-SemiBold", size: 34, relativeTo: .largeTitle))
                    Text("大切なレシピを、もっと一緒に。")
                        .font(.title3).foregroundStyle(secondaryInk)
                    Label("Estimated recipe & meal nutrition", systemImage: "leaf")
                    Label("追加のメニューブック", systemImage: "books.vertical")
                    Label("クラウド同期と復元", systemImage: "icloud")
                    Label("ブックを共有・友達は無料で参加", systemImage: "person.2")
                    Text("無料でもMy Menuにレシピを記録できます。Plus終了後も閲覧と書き出しは残ります。")
                        .font(.footnote).foregroundStyle(secondaryInk)
                    #if CRUMB_STOREKIT_LOCAL
                    Label("購入テスト専用・実際の請求はありません", systemImage: "testtube.2")
                        .font(.subheadline.weight(.semibold)).padding(14).background(.yellow.opacity(0.14), in: .rect(cornerRadius: 14))
                    Text("テスト購入では、この端末の追加ブックを試せます。クラウド同期・共有はサーバーの設定後に利用できます。")
                        .font(.footnote).foregroundStyle(secondaryInk)
                    #endif
                    if !PlusStore.purchasesEnabled {
                        Text("購入はまだ利用できません。").font(.footnote).foregroundStyle(secondaryInk)
                    }
                    if plus.hasPlus {
                        Label("Plusは有効です", systemImage: "checkmark.seal.fill").fontWeight(.semibold)
                        if let expiry = plus.expiresAt { Text(expiry, style: .date).font(.footnote).foregroundStyle(secondaryInk) }
                        Button("続ける") { CrumbHaptics.tap(); dismiss() }.foregroundStyle(.white).buttonStyle(.borderedProminent)
                    } else {
                        ForEach(plus.products, id: \.id) { product in
                            Button { CrumbHaptics.tap(); selected = product.id } label: {
                                HStack {
                                    Image(systemName: selected == product.id ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(LocalizedStringKey(product.id == PlusStore.yearlyID ? "年払い" : "月払い")).fontWeight(.semibold)
                                        Text(product.displayPrice + " / " + AppLanguage.text(product.id == PlusStore.yearlyID ? "年" : "月"))
                                    }
                                    Spacer()
                                }.foregroundStyle(ink).padding(18)
                                    .background(selected == product.id ? ink.opacity(0.06) : .white, in: .rect(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(fieldBorder))
                            }.buttonStyle(.plain).accessibilityAddTraits(selected == product.id ? .isSelected : [])
                        }
                        if plus.products.isEmpty {
                            Text("購入情報を取得できません。テスト用の起動設定を確認してください。")
                                .font(.footnote).foregroundStyle(secondaryInk)
                            Button("再読み込み") { CrumbHaptics.tap(); Task { await plus.loadProducts() } }
                        }
                        if let product = plus.products.first(where: { $0.id == selected }) ?? plus.products.first {
                            Button { CrumbHaptics.tap();
                                if plus.purchaseToken == nil { signIn = true }
                                else { Task { await plus.purchase(product) } }
                            } label: {
                                Text("Plusをはじめる").fontWeight(.semibold).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 52).background(ink, in: .capsule)
                            }.buttonStyle(.plain).disabled(plus.busy || !PlusStore.purchasesEnabled)
                            Text("サブスクリプションは自動更新されます。更新日の24時間前までにAppleの設定から解約できます。")
                                .font(.caption).foregroundStyle(secondaryInk)
                        }
                    }
                    HStack {
                        Button("購入を復元") { CrumbHaptics.tap(); Task { await plus.restore() } }
                        Spacer()
                        Button("購読を管理") { CrumbHaptics.tap(); manage = true }
                    }.font(.footnote).disabled(plus.busy)
                    if let privacy = PlusStore.policyURL("CrumbPrivacyURL") { Link("プライバシーポリシー", destination: privacy).hapticActivation().font(.footnote) }
                    if let terms = PlusStore.policyURL("CrumbTermsURL") { Link("利用規約", destination: terms).hapticActivation().font(.footnote) }
                    if plus.busy { ProgressView() }
                    if let message = plus.message { Text(message).font(.footnote).foregroundStyle(secondaryInk) }
                }.padding(24)
            }
            .foregroundStyle(ink).background(paper).navigationTitle("Crumb Plus").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { CrumbHaptics.tap(); dismiss() } } }
            .sheet(isPresented: $signIn) { AccountWelcome { signIn = false } }
            .manageSubscriptionsSheet(isPresented: $manage)
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await plus.reconcile() } } }
        }
    }
}

struct PlusSettingsSection: View {
    @EnvironmentObject private var plus: PlusStore
    @EnvironmentObject private var cloud: CloudLibrary
    @State private var showing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { CrumbHaptics.tap(); showing = true } label: {
                HStack {
                    Label("Crumb Plus", systemImage: "sparkles").fontWeight(.semibold)
                    Spacer()
                    Text(LocalizedStringKey(plus.hasPlus ? "Plus" : "Free")).foregroundStyle(secondaryInk)
                    Image(systemName: "chevron.right").font(.caption)
                }.frame(minHeight: 40)
            }.buttonStyle(.plain)
            if cloud.available {
                Button { CrumbHaptics.tap(); Task { await cloud.sync() } } label: {
                    Label("今すぐ同期", systemImage: "arrow.triangle.2.circlepath")
                }.disabled(cloud.syncing)
                if cloud.syncing { ProgressView() }
                if !plus.hasPlus {
                    Text("FreeのMy Menuは端末内に保存されます。共有ブックは所有者のPlusで同期します。")
                        .font(.caption).foregroundStyle(secondaryInk)
                }
                if let date = cloud.lastSync {
                    HStack { Text("クラウドの最終確認"); Text(date, style: .relative) }.font(.caption).foregroundStyle(secondaryInk)
                }
                if let error = cloud.error { Text(error).font(.footnote).foregroundStyle(secondaryInk) }
                if let notice = cloud.notice { Text(notice).font(.footnote) }
            } else {
                Text("クラウド同期・共有は準備中です。記録はこの端末に保存されます。")
                    .font(.footnote).foregroundStyle(secondaryInk)
            }
        }.padding(20).background(ink.opacity(0.035), in: .rect(cornerRadius: 22))
            .sheet(isPresented: $showing) { PlusView() }
    }
}
