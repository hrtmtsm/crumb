import SwiftUI
import SwiftData

@main
struct CrumbApp: App {
    @StateObject private var account = AccountStore()
    @AppStorage("appLanguage", store: .standard) private var language = AppLanguage.defaultCode
    // Keep the existing schema so recorded photos and recipes survive this UI change.
    private let store = try! ModelContainer(for: Meal.self, HomePlate.self,
        configurations: ModelConfiguration(cloudKitDatabase: .none))
    var body: some Scene {
        WindowGroup {
            AccountRoot(guestStore: store).environmentObject(account)
                .environment(\.locale, Locale(identifier: language)).id(language)
                .tint(clay).preferredColorScheme(.light)
        }
    }
}

struct AlbumView: View {
    @Query(sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var adding = false
    @State private var query = ""
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
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    NavigationLink { ProfileView() } label: {
                        ProfileAvatar(size: 44)
                    }.accessibilityLabel("プロフィールを開く")
                    VStack(alignment: .leading, spacing: 4) {
                        Menu {
                            ForEach(books) { book in
                                Button {
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
                            Button("メニューブックを追加", systemImage: "plus") {
                                newBookName = ""
                                addingBook = true
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(verbatim: selectedBook.name)
                                    .font(.custom("Nunito-SemiBold", size: 30, relativeTo: .title))
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                            }
                        }.accessibilityLabel("メニューブックを切り替え")
                    }
                    Spacer(minLength: 0)
                    Button {
                        showingSearch.toggle()
                        searchFocused = showingSearch
                        if !showingSearch { query = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 23, weight: .regular))
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel("レシピを検索")
                        .accessibilityValue(showingSearch ? Text("検索中") : Text(""))
                    Button { adding = true } label: {
                        Image(systemName: "plus").font(.headline)
                            .foregroundStyle(.white).frame(width: 44, height: 44).background(ink, in: .circle)
                    }.accessibilityLabel("レシピを追加")
                }.padding(20)
                if showingSearch {
                    HStack(spacing: 8) {
                        TextField("", text: $query, prompt:
                            Text("レシピを検索").foregroundColor(placeholderInk))
                            .font(.system(size: 16)).foregroundStyle(ink)
                            .accessibilityLabel("レシピを検索")
                            .focused($searchFocused)
                            .submitLabel(.search).onSubmit { searchFocused = false }
                        if !query.isEmpty {
                            Button { query = ""; searchFocused = true } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(secondaryInk)
                            }.accessibilityLabel("検索をクリア")
                        }
                    }
                    .padding(14).background(.white, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(fieldBorder))
                    .padding(.horizontal, 20).padding(.bottom, 12)
                }
                categoryFilters
                if recipes.isEmpty {
                    ContentUnavailableView(
                        LocalizedStringKey(query.isEmpty && selectedCategory == nil ? "レシピを残してみよう" : "レシピが見つかりません"),
                        systemImage: "book.closed",
                        description: Text(LocalizedStringKey(query.isEmpty && selectedCategory == nil ? "＋から料理の写真、材料、作り方を記録できます。" : "別の料理名やカテゴリで検索してください。")))
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15),
                                                 count: dynamicType.isAccessibilitySize ? 2 : 3), spacing: 24) {
                            ForEach(recipes) { meal in
                                NavigationLink { MealDetail(meal: meal) } label: { AlbumTile(meal: meal) }
                                    .buttonStyle(.plain)
                            }
                        }.padding(20)
                    }
                }
            }.background { AlbumPaper().ignoresSafeArea() }
                .foregroundStyle(ink).toolbar(.hidden, for: .navigationBar)
                .alert("メニューブックを追加", isPresented: $addingBook) {
                    TextField("メニューブック名", text: $newBookName)
                    Button("追加", action: createBook)
                        .disabled(newBookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("キャンセル", role: .cancel) { newBookName = "" }
                }
                .onChange(of: selectedBookID) { _, _ in
                    selectedCategory = nil
                    query = ""
                }
                .fullScreenCover(isPresented: $adding) {
                    RecipeCreationFlow(bookID: selectedBook.id)
                }
        }
    }
    private func createBook() {
        let name = newBookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let existing = books.first(where: { RecipeCategories.matches($0.name, name) }) {
            selectedBookID = existing.id
        } else {
            let book = MenuBook(id: UUID().uuidString, name: name)
            storedBooks = MenuBook.encode(books + [book])
            selectedBookID = book.id
        }
        selectedCategory = nil
        query = ""
        newBookName = ""
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
        return Button { selectedCategory = category } label: {
            Text(verbatim: category ?? "All")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .foregroundStyle(selected ? .white : ink)
                .background(selected ? ink : .white, in: .capsule)
                .overlay(Capsule().strokeBorder(ink.opacity(selected ? 0 : 0.12)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
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
    static var defaultCode: String {
        let code = Locale.preferredLanguages.first?.prefix(2).description ?? "en"
        return ["ja", "en", "ko"].contains(code) ? code : "en"
    }
    static var code: String { UserDefaults.standard.string(forKey: "appLanguage") ?? defaultCode }
    static var locale: Locale { Locale(identifier: code) }
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
                ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } }
            }
        }
    }
    private func languageRow(_ title: String, code: String) -> some View {
        Button { language = code } label: {
            HStack {
                Text(verbatim: title).foregroundStyle(ink)
                Spacer()
                if language == code { Image(systemName: "checkmark").foregroundStyle(ink) }
            }.frame(minHeight: 32)
        }.accessibilityAddTraits(language == code ? .isSelected : [])
    }
}
