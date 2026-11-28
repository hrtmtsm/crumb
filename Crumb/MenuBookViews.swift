import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MenuBookManager: View {
    @Query private var meals: [Meal]
    @EnvironmentObject private var plus: PlusStore
    @EnvironmentObject private var cloud: CloudLibrary
    @EnvironmentObject private var account: AccountStore
    @AppStorage("menuBooks") private var storedBooks = "[]"
    @AppStorage("selectedMenuBook") private var selectedBookID = MenuBook.defaultID
    @State private var adding = false
    @State private var paywall = false
    @State private var joining = false
    @State private var newName = ""
    @State private var busy = false
    @State private var error: String?
    @State private var sharing: MenuBook?
    @State private var export: BookExport?
    @State private var exporting = false
    var body: some View {
        List {
            ForEach(MenuBook.decode(storedBooks)) { original in
                let book = cloud.resolved(original)
                VStack(alignment: .leading, spacing: 12) {
                    Button { CrumbHaptics.tap(); selectedBookID = book.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: book.name).fontWeight(.semibold)
                                Text("\(recipes(book).count)レシピ").font(.caption).foregroundStyle(secondaryInk)
                            }
                            Spacer()
                            if selectedBookID == book.id { Image(systemName: "checkmark") }
                        }.foregroundStyle(ink).padding(.vertical, 5)
                    }
                    HStack(spacing: 24) {
                        Button("書き出す", systemImage: "square.and.arrow.up") { CrumbHaptics.tap();
                            export = BookExport(book: book, meals: recipes(book)); exporting = true
                        }.font(.footnote)
                        if PlanPolicy.isOwned(book, viewer: account.session?.userID) {
                            Button("招待", systemImage: "person.badge.plus") { CrumbHaptics.tap();
                                if plus.hasPlus { sharing = book } else { paywall = true }
                            }.font(.footnote)
                        } else {
                            Button("共有から抜ける", role: .destructive) { CrumbHaptics.tap(); run { try await cloud.leave(book) } }.font(.footnote)
                        }
                    }.buttonStyle(.borderless)
                }
            }
            Button("メニューブックを追加", systemImage: "plus") { CrumbHaptics.tap();
                newName = ""; if plus.hasPlus { adding = true } else { paywall = true }
            }
            Button("共有ブックに参加", systemImage: "link") { CrumbHaptics.tap(); joining = true }
            if busy { ProgressView() }
        }
        .navigationTitle("メニューブックを管理").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $paywall) { PlusView() }
        .sheet(isPresented: $joining) { JoinBookView() }
        .sheet(item: $sharing) { InviteBookView(book: $0) }
        .fileExporter(isPresented: $exporting, document: export, contentType: .json, defaultFilename: "Crumb-recipes") { result in
            if case .failure(let failure) = result { error = AppLanguage.errorMessage(failure) }
        }
        .alert("操作を完了できませんでした", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("閉じる", role: .cancel) { CrumbHaptics.tap() }
        } message: { Text(error ?? "") }
        .alert("メニューブックを追加", isPresented: $adding) {
            TextField("メニューブック名", text: $newName)
            Button("追加") { CrumbHaptics.tap();
                let clean = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                guard plus.hasPlus, !clean.isEmpty else { return }
                if plus.localTesting {
                    let book = MenuBook(id: UUID().uuidString, name: clean)
                    storedBooks = MenuBook.encode(MenuBook.decode(storedBooks) + [book]); selectedBookID = book.id
                } else { run { selectedBookID = try await cloud.createBook(clean).id } }
            }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            Button("キャンセル", role: .cancel) { CrumbHaptics.tap() }
        }
    }
    private func recipes(_ book: MenuBook) -> [Meal] { meals.filter { $0.wantToVisit != true && ($0.menuBookID ?? MenuBook.defaultID) == book.id } }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await operation() } catch { self.error = AppLanguage.errorMessage(error) } }
    }
}

struct InviteBookView: View {
    let book: MenuBook
    @EnvironmentObject private var cloud: CloudLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var link: URL?
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: book.name).font(.title3.bold())
                    Text("招待した人は、このブックのレシピ・写真・元写真を閲覧・編集できます。参加は無料です。")
                    Text("リンクは7日間有効で、1人が参加すると使用済みになります。信頼できる人に送ってください。")
                        .font(.footnote).foregroundStyle(secondaryInk)
                    if let link { ShareLink(item: link) { Label("招待を共有", systemImage: "square.and.arrow.up") }.hapticActivation() }
                    else {
                        Button("招待リンクを作成") { CrumbHaptics.tap();
                            busy = true
                            Task {
                                defer { busy = false }
                                do { link = URL(string: "crumb://join/" + (try await cloud.invite(to: book))) }
                                catch { message = AppLanguage.errorMessage(error) }
                            }
                        }.disabled(busy || !cloud.available)
                    }
                    Button("未使用の招待を取り消す", role: .destructive) { CrumbHaptics.tap();
                        Task {
                            do { try await cloud.revokeInvites(book); link = nil; message = AppLanguage.text("招待を取り消しました。") }
                            catch { message = AppLanguage.errorMessage(error) }
                        }
                    }.disabled(busy || !cloud.available)
                }
                if !cloud.available { Text("クラウド同期・共有は準備中です。記録はこの端末に保存されます。") }
                if busy { ProgressView() }
                if let message { Text(message).font(.footnote) }
            }.navigationTitle("友達を招待").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { CrumbHaptics.tap(); dismiss() } } }
        }
    }
}

struct JoinBookView: View {
    @EnvironmentObject private var cloud: CloudLibrary
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var invites: InviteRouter
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("共有ブックに参加") {
                    Text("招待された人のPlus購入は不要です。")
                    TextField("招待リンクまたはコード", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !account.signedIn { AppleAccountButton() }
                    Button("参加する") { CrumbHaptics.tap();
                        busy = true
                        Task {
                            defer { busy = false }
                            do { _ = try await cloud.join(input); invites.pending = nil; dismiss() }
                            catch { message = AppLanguage.errorMessage(error) }
                        }
                    }.disabled(busy || !account.signedIn || !cloud.available || InviteRouter.token(from: input) == nil)
                    if !cloud.available { Text("クラウド同期・共有は準備中です。記録はこの端末に保存されます。").font(.footnote) }
                    if busy { ProgressView() }
                    if let message { Text(message).font(.footnote) }
                }
            }.navigationTitle("共有ブックに参加").navigationBarTitleDisplayMode(.inline)
                .onAppear { input = invites.pending ?? "" }
                .onChange(of: input) { _, value in invites.pending = InviteRouter.token(from: value) }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { CrumbHaptics.tap(); dismiss() } } }
        }
    }
}

struct BookExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var bytes: Data
    init(book: MenuBook, meals: [Meal]) {
        struct Recipe: Encodable {
            let id: UUID; let name: String; let note: String; let date: Date?; let categories: [String]
            let recipe: String; let structuredRecipe: String?; let photo: Data; let originalPhoto: Data?
            let photoFraming: String?; let selectedPlateID: String?
        }
        struct Archive: Encodable { let version: Int; let name: String; let recipes: [Recipe] }
        let value = Archive(version: 1, name: book.name, recipes: meals.map {
            Recipe(id: $0.id, name: $0.name, note: $0.note, date: $0.recordedDate, categories: $0.categories,
                   recipe: $0.recipe, structuredRecipe: $0.structuredRecipe, photo: $0.photo, originalPhoto: $0.originalPhoto,
                   photoFraming: $0.photoFraming, selectedPlateID: $0.selectedPlateID)
        })
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        bytes = (try? encoder.encode(value)) ?? Data()
    }
    init(configuration: ReadConfiguration) throws { bytes = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}
