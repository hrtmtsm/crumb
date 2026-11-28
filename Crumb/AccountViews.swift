import SwiftUI
import SwiftData
import AuthenticationServices

// Guest data keeps its original container. Each authenticated user gets a separate local store and preferences.
struct AccountRoot: View {
    let guestStore: ModelContainer
    @EnvironmentObject private var account: AccountStore
    @State private var container: ModelContainer?
    @State private var defaults: UserDefaults = .standard
    @State private var readyScope = ""
    @State private var storageFailed = false
    @AppStorage("hasPassedWelcome", store: .standard) private var passedWelcome = false
    @AppStorage("onboardingVersion", store: .standard) private var onboardingVersion = 0

    var body: some View {
        Group {
            if account.restoring || readyScope != account.scope {
                CrumbLaunchView()
            } else if onboardingVersion < 1 {
                CrumbOnboarding { onboardingVersion = 1 }
            } else if !passedWelcome && !account.signedIn {
                AccountWelcome { passedWelcome = true }
            } else if let container {
                AccountHome(defaults: defaults)
                    .modelContainer(container)
                    .defaultAppStorage(defaults)
                    .id(readyScope)
            }
        }
        .background(paper.ignoresSafeArea())
        .task { await account.restore() }
        .task(id: account.scope) { prepareScope() }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
            account.credentialsRevoked()
        }
        .alert("記録を開けませんでした", isPresented: $storageFailed) {
            Button("もう一度試す") { CrumbHaptics.tap(); prepareScope() }
        } message: { Text("記録は削除せずに保持しています。もう一度お試しください。") }
    }

    private func prepareScope() {
        do {
            if account.scope == "guest" {
                container = guestStore
                defaults = .standard
            } else {
                let directory = URL.applicationSupportDirectory.appendingPathComponent("Accounts", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let config = ModelConfiguration(url: directory.appendingPathComponent(account.scope + ".store"), cloudKitDatabase: .none)
                container = try ModelContainer(for: Meal.self, HomePlate.self, configurations: config)
                guard let scoped = UserDefaults(suiteName: account.preferenceSuite) else { throw AccountError.storage }
                defaults = scoped
                if defaults.string(forKey: "profileName")?.isEmpty != false,
                   let name = account.session?.displayName { defaults.set(name, forKey: "profileName") }
            }
            readyScope = account.scope
        } catch { storageFailed = true }
    }
}

private struct AccountHome: View {
    let defaults: UserDefaults
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var invites: InviteRouter
    @StateObject private var plus = PlusStore()
    @StateObject private var cloud = CloudLibrary()
    @State private var joining = false
    @EnvironmentObject private var account: AccountStore
    @AppStorage("profileSetupDone") private var profileDone = false
    @AppStorage("profileName") private var name = ""
    var body: some View {
        Group {
            if account.signedIn && !profileDone {
                VStack(spacing: 24) {
                    ProfileAvatar(size: 88)
                    Text("プロフィールを設定").font(.custom("Nunito-SemiBold", size: 28, relativeTo: .title))
                    TextField("名前", text: $name).textFieldStyle(.roundedBorder).textContentType(.nickname)
                    Button("はじめる") { CrumbHaptics.tap();
                        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        profileDone = true
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("あとで設定する") { CrumbHaptics.tap(); profileDone = true }.foregroundStyle(secondaryInk)
                }.padding(30).foregroundStyle(ink)
            } else { AlbumView() }
        }
        .environmentObject(plus).environmentObject(cloud)
        .task {
            cloud.configure(account: account, context: context, defaults: defaults)
            await plus.configure(account: account)
            await cloud.sync()
            if invites.pending != nil { joining = true }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await plus.reconcile()
            while !Task.isCancelled {
                await cloud.sync()
                try? await Task.sleep(for: .seconds(45))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .crumbLibraryChanged)) { _ in Task { await cloud.sync() } }
        .onChange(of: plus.hasPlus) { _, _ in Task { await cloud.sync() } }
        .onChange(of: invites.pending) { _, token in if token != nil { joining = true } }
        .sheet(isPresented: $joining) { JoinBookView().environmentObject(cloud).environmentObject(plus) }
    }
}

struct AccountWelcome: View {
    @EnvironmentObject private var account: AccountStore
    let continueAsGuest: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("CrumbAvatar").resizable().scaledToFit().frame(width: 112, height: 112)
            Text("crumb").font(crumbFont(48))
            Text("料理を残す、わたしのレシピ帳。")
                .font(.custom("Nunito-Regular", size: 20, relativeTo: .title3))
                .multilineTextAlignment(.center).foregroundStyle(secondaryInk)
            Spacer()
            AppleAccountButton()
            Button("ログインせず使う", action: CrumbHaptics.action(continueAsGuest))
                .font(.system(.body).weight(.semibold)).frame(minHeight: 44)
            Text("レシピはこの端末に保存されます。")
                .font(.footnote).foregroundStyle(secondaryInk)
                .multilineTextAlignment(.center)
        }
        .padding(28).padding(.bottom, 16)
        .foregroundStyle(ink).background(paper.ignoresSafeArea())
        .alert("ログインできませんでした", isPresented: Binding(get: { account.error != nil }, set: { if !$0 { account.error = nil } })) {
            Button("閉じる", role: .cancel) { CrumbHaptics.tap(); account.error = nil }
        } message: { Text(account.error ?? "") }
    }
}

struct AppleAccountButton: View {
    @EnvironmentObject private var account: AccountStore
    var body: some View {
        Group {
            if account.configured {
                SignInWithAppleButton(.continue) { request in
                    account.prepareApple(request)
                } onCompletion: { result in
                    Task { await account.signIn(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52).clipShape(.rect(cornerRadius: 14))
                .disabled(account.busy)
            } else {
                Button { CrumbHaptics.tap();
                    account.error = AccountError.notConfigured.localizedDescription
                } label: {
                    Label("Appleで続ける", systemImage: "apple.logo")
                        .font(.system(.body).weight(.semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(.black, in: .rect(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
        }.overlay { if account.busy { ProgressView().tint(.white) } }
    }
}

struct AccountSettingsSection: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.modelContext) private var context
    @State private var signIn = false
    @State private var confirmSignOut = false
    @State private var confirmDeletion = false
    @State private var verifyDeletion = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("アカウント").font(.subheadline.weight(.semibold)).foregroundStyle(secondaryInk)
            if let session = account.session {
                Label("Appleでログイン中", systemImage: "checkmark.shield")
                    .font(.system(.body).weight(.semibold))
                if let email = session.email { Text(email).font(.footnote).foregroundStyle(secondaryInk).textSelection(.enabled) }
                Button("ログアウト") { CrumbHaptics.tap(); confirmSignOut = true }.disabled(account.busy)
                Button("アカウントを削除", role: .destructive) { CrumbHaptics.tap(); confirmDeletion = true }.disabled(account.busy)
            } else {
                Text("ログインせずに利用中").font(.subheadline).foregroundStyle(secondaryInk)
                Button { CrumbHaptics.tap(); signIn = true } label: {
                    Label("Appleで登録・ログイン", systemImage: "apple.logo")
                        .font(.system(.body).weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(ink.opacity(0.035), in: .rect(cornerRadius: 22))
        .sheet(isPresented: $signIn) {
            AccountWelcome { signIn = false }
        }
        .onChange(of: account.signedIn) { _, signedIn in if signedIn { signIn = false } }
        .confirmationDialog("ログアウトしますか？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("ログアウト") { CrumbHaptics.tap(); Task { await account.signOut() } }
        } message: { Text("このアカウントの端末内の記録は、再ログインすると開けます。") }
        .confirmationDialog("アカウントを削除しますか？", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Appleで本人確認して削除", role: .destructive) { CrumbHaptics.tap(); verifyDeletion = true }
        } message: { Text("このアカウントと所有するブック・写真を削除します。取り消せません。ログインせずに保存した記録は残ります。Appleの購読は別途解約してください。") }
        .sheet(isPresented: $verifyDeletion) {
            VStack(spacing: 24) {
                Text("アカウントを削除").font(.title2.bold())
                Text("削除するアカウントをAppleで確認してください。")
                SignInWithAppleButton(.continue) { account.prepareApple($0) } onCompletion: { result in
                    Task {
                        let deleted = await account.deleteAccount(result) {
                            try context.delete(model: Meal.self)
                            try context.delete(model: HomePlate.self)
                            try context.save()
                            UserDefaults.standard.removePersistentDomain(forName: account.preferenceSuite)
                        }
                        if deleted { verifyDeletion = false }
                    }
                }
                .signInWithAppleButtonStyle(.black).frame(height: 52).disabled(account.busy)
                Button("キャンセル") { CrumbHaptics.tap(); verifyDeletion = false }.disabled(account.busy)
                if account.busy { ProgressView() }
                if let error = account.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }.padding(28).presentationDetents([.medium])
        }
        .alert("操作を完了できませんでした", isPresented: Binding(get: { account.error != nil && !signIn && !verifyDeletion }, set: { if !$0 { account.error = nil } })) {
            Button("閉じる", role: .cancel) { CrumbHaptics.tap(); account.error = nil }
        } message: { Text(account.error ?? "") }
    }
}

extension AccountStore {
    var preferenceSuite: String { (Bundle.main.bundleIdentifier ?? "crumb") + ".account." + scope }
}

struct CrumbLaunchView: View {
    var body: some View {
        VStack(spacing: 22) {
            Image("CrumbAvatar").resizable().scaledToFit().frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Text("crumb").font(crumbFont(44)).foregroundStyle(ink)
            ProgressView().tint(secondaryInk).padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paper.ignoresSafeArea())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("レシピ帳を開いています")
    }
}

struct CrumbOnboarding: View {
    let onComplete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    private let titles: [LocalizedStringKey] = ["今日のひと皿を、残そう。", "おいしかった、をレシピに。", "あなただけのメニューブック。"]
    private let descriptions: [LocalizedStringKey] = [
        "写真を撮るか、アルバムから選んで。形やお皿を選んで、あなたらしい一枚に。",
        "材料と作り方を添えて記録。人数に合わせた分量で、また作りたくなるレシピに。",
        "カテゴリやメニューブックで整理して、お気に入りを見つけやすく。"
    ]
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 16) {
                HStack {
                    Text("crumb").font(crumbFont(28))
                    Spacer()
                    Button("スキップ", action: CrumbHaptics.action(onComplete))
                        .font(.system(.subheadline).weight(.medium))
                        .foregroundStyle(secondaryInk).frame(minHeight: 44)
                }.padding(.horizontal, 24)

                TabView(selection: $page) {
                    ForEach(0..<3) { index in
                        ScrollView {
                            VStack(spacing: 26) {
                                onboardingIllustration(index)
                                    .frame(height: min(290, max(170, geometry.size.height * 0.39)))
                                    .accessibilityHidden(true)
                                VStack(spacing: 14) {
                                    Text(titles[index])
                                        .font(.custom("Nunito-SemiBold", size: 30, relativeTo: .title))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityAddTraits(.isHeader)
                                    Text(descriptions[index])
                                        .font(.system(.body)).foregroundStyle(secondaryInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.multilineTextAlignment(.center).frame(maxWidth: 360)
                            }.padding(.horizontal, 24).padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                        }.tag(index)
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 9) {
                    ForEach(0..<3) { index in
                        Button { CrumbHaptics.tap(); go(to: index) } label: {
                            Capsule().fill(index == page ? ink : fieldBorder)
                                .frame(width: index == page ? 22 : 7, height: 7)
                                .frame(minWidth: 32, minHeight: 32)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(Text("紹介ページ\(index + 1)"))
                            .accessibilityAddTraits(index == page ? .isSelected : [])
                    }
                }
                Button { CrumbHaptics.tap();
                    if page == 2 { onComplete() } else { go(to: page + 1) }
                } label: {
                    HStack {
                        Text(page == 2 ? LocalizedStringKey("はじめる") : LocalizedStringKey("次へ"))
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(.body).weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(ink, in: .capsule)
                }.buttonStyle(.plain).padding(.horizontal, 24)
            }
            .padding(.top, 10).padding(.bottom, 20)
            .foregroundStyle(ink).background(paper.ignoresSafeArea())
        }
    }

    private func go(to index: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = index }
    }

    @ViewBuilder private func onboardingIllustration(_ index: Int) -> some View {
        if index == 0 {
            ZStack {
                Circle().fill(ink.opacity(0.025)).frame(width: 240, height: 240)
                samplePhoto("curry", size: 136).rotationEffect(.degrees(-13)).offset(x: -82, y: -16)
                samplePhoto("pudding", size: 130).rotationEffect(.degrees(12)).offset(x: 85, y: 8)
                VStack(spacing: 12) {
                    samplePhoto("carbonara", size: 160)
                    Text("Carbonara").font(.custom("Nunito-SemiBold", size: 16))
                }
                .padding(12).background(.white, in: .rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(fieldBorder))
                .shadow(color: ink.opacity(0.06), radius: 14, y: 8)
                .rotationEffect(.degrees(-3)).offset(y: 16)
            }
        } else if index == 1 {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("材料").font(.custom("Nunito-SemiBold", size: 22))
                    Spacer()
                    Text("2人前").font(.subheadline).foregroundStyle(secondaryInk)
                }
                HStack { Text("パスタ"); Spacer(); Text("100 g") }
                HStack { Text("卵"); Spacer(); Text("1") }
                Divider()
                Text("作り方").font(.custom("Nunito-SemiBold", size: 22))
                HStack(alignment: .top, spacing: 12) {
                    Text("1.").fontWeight(.semibold)
                    Text("パスタをゆでて、卵とチーズを合わせる。")
                        .font(.subheadline).foregroundStyle(secondaryInk)
                }
            }
            .padding(24).frame(maxWidth: 290)
            .background(.white, in: .rect(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(fieldBorder))
            .shadow(color: ink.opacity(0.045), radius: 14, y: 8)
            .rotationEffect(.degrees(-3))
        } else {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Image(systemName: "book.closed")
                    Text("My Menu").font(.custom("Nunito-SemiBold", size: 25))
                }
                HStack(spacing: 8) {
                    Text("All").foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8).background(ink, in: .capsule)
                    Text("朝ごはん").padding(.horizontal, 14).padding(.vertical, 8).background(ink.opacity(0.05), in: .capsule)
                    Text("夜食").padding(.horizontal, 14).padding(.vertical, 8).background(ink.opacity(0.05), in: .capsule)
                }.font(.caption)
                HStack(spacing: 12) {
                    samplePhoto("carbonara", size: 76)
                    samplePhoto("curry", size: 76)
                    samplePhoto("pudding", size: 76)
                }
            }
            .padding(22).background(.white, in: .rect(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(fieldBorder))
            .shadow(color: ink.opacity(0.045), radius: 14, y: 8)
        }
    }

    private func samplePhoto(_ name: String, size: CGFloat) -> some View {
        Group {
            if let path = Bundle.main.path(forResource: name, ofType: "jpg"), let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else { Circle().fill(ink.opacity(0.05)).overlay(Image(systemName: "fork.knife")) }
        }
        .frame(width: size, height: size).clipShape(.circle)
        .overlay(Circle().stroke(.white, lineWidth: 5))
    }
}
