import SwiftUI
import SwiftData

@main
struct CrumbApp: App {
    @StateObject private var account = AccountStore()
    @StateObject private var invites = InviteRouter()
    @AppStorage("appLanguage", store: .standard) private var language = AppLanguage.defaultCode
    // Keep the existing schema so recorded photos and recipes survive this UI change.
    private let store = try! ModelContainer(for: Meal.self, HomePlate.self,
        configurations: ModelConfiguration(cloudKitDatabase: .none))
    init() {
        if !UserDefaults.standard.bool(forKey: "assistantEnglishV1") {
            UserDefaults.standard.set("en", forKey: "appLanguage")
            UserDefaults.standard.set(true, forKey: "assistantEnglishV1")
        }
    }
    var body: some Scene {
        WindowGroup {
            AccountRoot(guestStore: store).environmentObject(account).environmentObject(invites)
                .onOpenURL { invites.open($0) }
                .environment(\.locale, Locale(identifier: language)).id(language)
                .tint(clay).preferredColorScheme(.light)
        }
    }
}

enum AlbumRoute: Hashable {
    case profile
    case recipe(UUID)
    case books
}

struct AlbumView: View {
    @EnvironmentObject private var routes: InviteRouter
    @EnvironmentObject private var plus: PlusStore
    @EnvironmentObject private var cloud: CloudLibrary
    @EnvironmentObject private var account: AccountStore
    @State private var paywall = false
    @State private var creating = false
    @State private var failure: String?
    private var editable: Bool { PlanPolicy.canEdit(book: cloud.resolved(selectedBook), viewer: account.session?.userID, plus: plus.hasPlus) }
    @Query(sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var rootTab = 0
    @State private var rootKeyboardVisible = false
    @State private var adding = false
    @State private var query = ""
    @State private var path: [AlbumRoute] = []
    @State private var importDraft: RecipeDraft?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    @State private var selectedCategory: String?
    @AppStorage("recipeCategories") private var storedCategories = "[]"
    @AppStorage("menuBooks") private var storedBooks = "[]"
    @AppStorage("selectedMenuBook") private var selectedBookID = MenuBook.defaultID
    @State private var addingBook = false
    @State private var newBookName = ""
    private var books: [MenuBook] { MenuBook.decode(storedBooks) }
    private var selectedBook: MenuBook { books.first { $0.id == selectedBookID } ?? .defaultBook }


    private var recipes: [Meal] {
        meals.filter { meal in
            meal.wantToVisit != true &&
            (meal.menuBookID ?? MenuBook.defaultID) == selectedBook.id &&
            (selectedCategory.map { category in meal.categories.contains { RecipeCategories.matches($0, category) } } ?? true) &&
            (query.isEmpty || (meal.name + " " + meal.note + " " + meal.recipe + " " + (meal.structuredRecipe ?? ""))
                .localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $rootTab) {
                menuPage.toolbar(.hidden, for: .tabBar).tag(0)
                AskCrumbView(embedded: true).toolbar(.hidden, for: .tabBar).tag(1)
            }.toolbar(.hidden, for: .tabBar)
            if !rootKeyboardVisible { rootNavigationBar }
        }
        .background(.white)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in rootKeyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in rootKeyboardVisible = false }
    }
    private var rootNavigationBar: some View {
            HStack(spacing: 28) {
                rootTabButton("Menu", symbol: "book", tab: 0)
                Button { openAddRecipe() } label: {
                    Image(systemName: "plus").font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.white).frame(width: 56, height: 56).background(ink, in: .circle)
                }.buttonStyle(.plain).accessibilityLabel("レシピを追加")
                rootTabButton("Explore", symbol: "sparkles", tab: 1)
            }
            .padding(.horizontal, 26).padding(.vertical, 10)
            .frame(maxWidth: .infinity).background(.white)
            .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.08)).frame(height: 0.5) }
    }
    private func rootTabButton(_ title: LocalizedStringKey, symbol: String, tab: Int) -> some View {
        Button { CrumbHaptics.selection(); rootTab = tab } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 22))
                Text(title).font(.caption.weight(rootTab == tab ? .semibold : .regular))
            }.foregroundStyle(rootTab == tab ? ink : secondaryInk).frame(maxWidth: .infinity, minHeight: 48)
        }.buttonStyle(.plain).accessibilityAddTraits(rootTab == tab ? .isSelected : [])
    }
    private func openAddRecipe() {
        CrumbHaptics.tap()
        rootTab = 0
        if editable { adding = true }
        else if PlanPolicy.isOwned(cloud.resolved(selectedBook), viewer: account.session?.userID) { paywall = true }
        else { failure = AppLanguage.text("この操作にはブック所有者の有効なPlusが必要です。") }
    }
    private var menuPage: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    NavigationLink(value: AlbumRoute.profile) {
                        ProfileAvatar(size: 44)
                    }.accessibilityLabel("プロフィールを開く")
                    VStack(alignment: .leading, spacing: 4) {
                        Menu {
                            ForEach(books) { book in
                                Button { CrumbHaptics.tap();
                                    selectedBookID = book.id
                                    selectedCategory = nil
                                    query = ""
                                } label: {
                                    if selectedBook.id == book.id {
                                        Label(book.name, systemImage: "checkmark")
                                    } else { Text(verbatim: book.name) }
                                }
                            }
                            Divider()
                            Button("メニューブックを追加", systemImage: "plus") { CrumbHaptics.tap();
                                newBookName = ""
                                if plus.hasPlus { addingBook = true } else { paywall = true }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: selectedBook.name)
                                    .font(.custom("Nunito-SemiBold", size: 30, relativeTo: .title))
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                            }
                        }.hapticActivation().accessibilityLabel("メニューブックを切り替え")
                    }
                    Spacer(minLength: 0)
                    Button { CrumbHaptics.tap();
                        showingSearch.toggle()
                        searchFocused = showingSearch
                        if !showingSearch { query = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 23, weight: .regular))
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel("レシピを検索")
                        .accessibilityValue(showingSearch ? Text("検索中") : Text(""))

                }.padding(20)
                if showingSearch {
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            TextField("", text: $query, prompt:
                                Text("レシピを検索").foregroundColor(placeholderInk))
                                .font(.system(size: 16)).foregroundStyle(ink)
                                .accessibilityLabel("レシピを検索")
                                .focused($searchFocused)
                                .submitLabel(.search).onSubmit { searchFocused = false }
                            if !query.isEmpty {
                                Button { CrumbHaptics.tap(); query = ""; searchFocused = true } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(secondaryInk)
                                }.accessibilityLabel("検索をクリア")
                            }
                        }
                        .padding(14).background(.white, in: .rect(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(fieldBorder))
                        Button("キャンセル") { CrumbHaptics.tap();
                            query = ""
                            searchFocused = false
                            showingSearch = false
                        }
                        .font(.system(size: 16))
                        .foregroundStyle(ink)
                        .fixedSize()
                        .frame(minHeight: 44)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 12)
                }
                categoryFilters
                if !editable {
                    Label("閲覧のみ・レシピの書き出しはブック管理からできます。", systemImage: "lock")
                        .font(.caption).foregroundStyle(secondaryInk).padding(.horizontal, 20).padding(.bottom, 8)
                }
                if recipes.isEmpty {
                    if query.isEmpty && selectedCategory == nil {
                        EmptyRecipeView(onAdd: editable ? { CrumbHaptics.add(); adding = true } : nil)
                    } else {
                        ContentUnavailableView("レシピが見つかりません", systemImage: "magnifyingglass",
                                               description: Text("別の料理名やカテゴリで検索してください。"))
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15),
                                                 count: dynamicType.isAccessibilitySize ? 2 : 3), spacing: 24) {
                            ForEach(recipes) { meal in
                                NavigationLink(value: AlbumRoute.recipe(meal.id)) { AlbumTile(meal: meal) }
                                    .buttonStyle(.plain)
                            }
                        }.padding(20)
                    }
                }
            }
            .navigationDestination(for: AlbumRoute.self) { route in
                switch route {
                case .profile: ProfileView()
                case .books: MenuBookManager()
                case .recipe(let id):
                    if let meal = meals.first(where: { $0.id == id }) { MealDetail(meal: meal, canEdit: editable) }
                }
            }
            .onChange(of: path) { _, _ in CrumbHaptics.tap() }
            .background { AlbumPaper().ignoresSafeArea() }
                .foregroundStyle(ink).toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $paywall) { PlusView() }
                .alert("操作を完了できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button("閉じる", role: .cancel) { CrumbHaptics.tap() }
                } message: { Text(failure ?? "") }
                .alert("メニューブックを追加", isPresented: $addingBook) {
                    TextField("メニューブック名", text: $newBookName)
                    Button("追加", action: CrumbHaptics.action(createBook))
                        .disabled(newBookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("キャンセル", role: .cancel) { CrumbHaptics.tap(); newBookName = "" }
                }
                .onChange(of: selectedBookID) { _, _ in
                    selectedCategory = nil
                    query = ""
                }
                .fullScreenCover(isPresented: $adding) {
                    RecipeCreationFlow(bookID: selectedBook.id)
                }
                .sheet(item: $importDraft) { draft in
                    MealEditor(meal: nil, initialBookID: selectedBook.id, draft: draft)
                }
                .onAppear { receiveImport() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { receiveImport() } }
                .onChange(of: routes.recipeSource) { _, _ in receiveImport() }
                .onChange(of: adding) { _, active in if !active { receiveImport() } }
                .onChange(of: path) { _, value in if value.isEmpty { receiveImport() } }
        }
    }
    private func receiveImport() {
        guard importDraft == nil, !adding, path.isEmpty else { return }
        if let source = routes.recipeSource {
            routes.recipeSource = nil
            openImport(source)
        } else if let source = RecipeInbox.take() { openImport(source) }
    }
    private func openImport(_ source: String) {
        var recipe = MealRecipe(); recipe.servingsKnown = false
        importDraft = RecipeDraft(title: "", recipe: recipe, source: source)
    }
    private func createBook() {
        let name = newBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plus.hasPlus, !name.isEmpty, !creating else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                let book: MenuBook
                if plus.localTesting {
                    book = MenuBook(id: UUID().uuidString, name: name)
                    storedBooks = MenuBook.encode(books + [book])
                } else { book = try await cloud.createBook(name) }
                selectedBookID = book.id; selectedCategory = nil; query = ""; newBookName = ""
            } catch { failure = AppLanguage.errorMessage(error) }
        }
    }

    private var categoryFilters: some View {
        let names = RecipeCategories.normalized(RecipeCategories.decode(storedCategories) + meals.filter { $0.wantToVisit != true }.flatMap(\.categories))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryFilter(nil)
                ForEach(names, id: \.self) { category in categoryFilter(category) }
            }.padding(.horizontal, 20).padding(.bottom, 12)
        }
        .onChange(of: names) { _, updated in
            if let selectedCategory, !updated.contains(where: { RecipeCategories.matches($0, selectedCategory) }) {
                self.selectedCategory = nil
            }
        }
    }

    private func categoryFilter(_ category: String?) -> some View {
        let selected = selectedCategory == category
        return Button { CrumbHaptics.tap(); selectedCategory = category } label: {
            Text(verbatim: category ?? AppLanguage.text("All"))
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .foregroundStyle(selected ? .white : ink)
                .background(selected ? ink : .white, in: .capsule)
                .overlay(Capsule().strokeBorder(ink.opacity(selected ? 0 : 0.12)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
        .categoryActions(category, enabled: editable, canEdit: { id in
            guard let book = books.first(where: { $0.id == id }) else { return false }
            return PlanPolicy.canEdit(book: cloud.resolved(book), viewer: account.session?.userID, plus: plus.hasPlus)
        }) { old, replacement in
            if let selectedCategory, RecipeCategories.matches(selectedCategory, old) {
                self.selectedCategory = replacement
            }
        }
    }

}

struct AlbumTile: View {
    let meal: Meal

    var body: some View {
        VStack(spacing: 5) {
            PlatePhoto(meal: meal, pixels: 420)
                .aspectRatio(1, contentMode: .fit)
            Text(meal.title)
                .font(.custom("Nunito-SemiBold", size: 16, relativeTo: .subheadline))
                .lineSpacing(0)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.top, 3)
            if MealRecipe(contents: meal.structuredRecipe).isMeal { Label("Meal", systemImage: "square.stack").font(.caption).foregroundStyle(secondaryInk) }
            if let date = meal.recordedDate {
                Text(dayLabel(date))
                .font(.system(size: 12))
                .foregroundStyle(secondaryInk)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meal-\(meal.title)")
    }
}

struct PlatePhoto: View {
    let meal: Meal
    let pixels: Int

    var body: some View {
        let photo = MealPhoto(data: meal.photo, size: pixels, contentMode: .fit)
        if meal.photo.isPlatedPhoto {
            photo.shadow(color: ink.opacity(0.08), radius: 1, x: 0, y: 1)
        } else {
            photo.clipShape(.rect(cornerRadius: 10))
        }
    }
}

struct AlbumPaper: View {
    var body: some View { paper }
}

enum AppLanguage {
    static var defaultCode: String { "en" }
    static var code: String { UserDefaults.standard.string(forKey: "appLanguage") ?? defaultCode }
    static var locale: Locale { Locale(identifier: code) }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
    static func errorMessage(_ error: Error) -> String {
        if let known = error as? CloudError { return known.localizedDescription }
        if let known = error as? AccountError { return known.localizedDescription }
        return text("操作を完了できませんでした。もう一度お試しください。")
    }
    static func text(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
struct LanguageSettings: View {
    @AppStorage("appLanguage", store: .standard) private var language = AppLanguage.defaultCode
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("言語") {
                    languageRow("日本語", code: "ja")
                    languageRow("English", code: "en")
                    languageRow("한국어", code: "ko")
                }
            }
            .navigationTitle("設定").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完了") { CrumbHaptics.tap(); dismiss() } }
            }
        }
    }
    private func languageRow(_ title: String, code: String) -> some View {
        Button { CrumbHaptics.tap(); language = code } label: {
            HStack {
                Text(verbatim: title).foregroundStyle(ink)
                Spacer()
                if language == code { Image(systemName: "checkmark").foregroundStyle(ink) }
            }.frame(minHeight: 32)
        }.accessibilityAddTraits(language == code ? .isSelected : [])
    }
}
