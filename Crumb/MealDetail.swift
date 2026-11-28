import SwiftUI
import SwiftData

struct MealDetail: View {
    @EnvironmentObject private var plus: PlusStore
    @EnvironmentObject private var cloud: CloudLibrary
    @EnvironmentObject private var account: AccountStore
    @AppStorage("menuBooks") private var storedBooks = "[]"
    private var mayEdit: Bool {
        let id = meal.menuBookID ?? MenuBook.defaultID
        guard let book = MenuBook.decode(storedBooks).first(where: { $0.id == id }) else { return false }
        return canEdit && PlanPolicy.canEdit(book: cloud.resolved(book), viewer: account.session?.userID, plus: plus.hasPlus)
    }
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false
    @State private var deletionFailed = false
    let meal: Meal
    var canEdit = true
    @State private var editing = false
    @State private var origin: Meal?
    @Query private var library: [Meal]
    @State private var viewingRecipe = false
    @State private var shareAfterRecipe = false
    @State private var servingOverride: Int?

    private var structured: MealRecipe { MealRecipe(contents: meal.structuredRecipe) }
    private var hasRecipe: Bool { !structured.isEmpty || !meal.recipe.isEmpty || link != nil }
    private var servings: Int { servingOverride ?? structured.servings }

    @State private var shareCard: ShareCard?
    @State private var shareError = false

    private var originalMeal: Meal? {
        guard let id = structured.originRecipeID else { return nil }
        return library.first { candidate in candidate.id == id }
    }

    private var mealSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(meal.title).font(.largeTitle).bold().accessibilityAddTraits(.isHeader)
            if let date = meal.recordedDate { Text(dayLabel(date)).foregroundStyle(clay) }
            if !meal.note.isEmpty { Text(meal.note).padding(.top, 5) }
            IngredientTagLayout(spacing: 7) {
                ForEach(meal.categories, id: \.self) { category in
                    Text(verbatim: category).font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(ink.opacity(0.06), in: .capsule)
                }
            }
        }
    }

    @ViewBuilder private var recipeActions: some View {
        if structured.isMeal { MealDishesView(meal: meal, canEdit: mayEdit) }
        if structured.coverIsAI == true { Text("AI preview").font(.caption).foregroundStyle(secondaryInk) }
        if let original = originalMeal {
            Button("Adapted from \(original.title)") { origin = original }.font(.footnote)
        }
        if let link { Link("Source", destination: link).font(.subheadline) }
        if hasRecipe {
            Divider()
            Button { CrumbHaptics.tap(); viewingRecipe = true } label: {
                Label("レシピを見る", systemImage: "book")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }.buttonStyle(.borderedProminent).tint(ink)
        }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MealPhoto(data: meal.photo, size: 1250)
                    .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 24))
                mealSummary
                recipeActions
            }.padding(24)
        }
    }

    var body: some View {
        detailContent
        .foregroundStyle(ink)
        .background(paper.ignoresSafeArea())
        .navigationTitle("レシピ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("料理写真を共有", systemImage: "photo") { CrumbHaptics.tap(); share(recipe: false) }
                    if hasRecipe {
                        Button("レシピを共有", systemImage: "book") { CrumbHaptics.tap(); share(recipe: true) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }.accessibilityLabel("共有").hapticActivation()
            }
            if mayEdit {
                ToolbarItem(placement: .primaryAction) {
                    Menu("操作", systemImage: "ellipsis.circle") {
                        if meal.wantToVisit != true { Button("編集", systemImage: "pencil") { CrumbHaptics.tap(); editing = true } }
                        Button("料理を削除", systemImage: "trash", role: .destructive) { CrumbHaptics.tap(); confirmingDeletion = true }
                    }.hapticActivation()
                }
            }
        }
        .confirmationDialog("この料理を削除しますか？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("削除", role: .destructive) { CrumbHaptics.tap();
                do {
                    guard mayEdit else { deletionFailed = true; return }
                    context.delete(meal)
                    try context.save()
                    NotificationCenter.default.post(name: .crumbLibraryChanged, object: nil)
                    dismiss()
                } catch {
                    context.rollback()
                    deletionFailed = true
                }
            }
        } message: {
            Text("このブックからレシピを削除します。同期すると共有メンバーにも反映されます。")
        }
        .alert("料理を削除できませんでした", isPresented: $deletionFailed) {
            Button("閉じる", role: .cancel) { CrumbHaptics.tap() }
        }
        .sheet(isPresented: $viewingRecipe, onDismiss: {
            if shareAfterRecipe {
                shareAfterRecipe = false
                share(recipe: true)
            }
        }) {
            NavigationStack {
                RecipeReader(meal: meal, recipe: structured, servings: Binding(
                    get: { servings }, set: { servingOverride = $0 }
                ), link: link, canEdit: mayEdit) {
                    shareAfterRecipe = true
                    viewingRecipe = false
                }
                .navigationTitle("レシピ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { CrumbHaptics.tap(); viewingRecipe = false }
                    }
                }
            }
        }
        .sheet(item: $origin) { original in
            NavigationStack { MealDetail(meal: original).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { origin = nil } } } }
        }
        .sheet(isPresented: $editing) { MealEditor(meal: meal) }
        .sheet(item: $shareCard) { SharePreview(card: $0) }
        .alert("カードを作成できませんでした", isPresented: $shareError) {
            Button("閉じる", role: .cancel) { CrumbHaptics.tap() }
        }
    }

    private var link: URL? {
        guard let url = URL(string: meal.recipeURL),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    @MainActor private func share(recipe: Bool, includePlace: Bool = false) {
        if let image = renderShare(recipe: recipe, includePlace: includePlace, showLogo: true) {
            shareCard = ShareCard(image: image, description: meal.title) { logo in
                renderShare(recipe: recipe, includePlace: includePlace, showLogo: logo)
            }
        } else {
            shareError = true
        }
    }

    @MainActor private func renderShare(recipe: Bool, includePlace: Bool, showLogo: Bool) -> UIImage? {
        let renderer = ImageRenderer(content:
            VStack(alignment: .leading, spacing: 19) {
                if showLogo {
                    HStack(spacing: 8) {
                        Image("CrumbAvatar").renderingMode(.original).resizable().scaledToFit()
                            .frame(width: 32, height: 32)
                        Text("crumb").font(crumbFont(22))
                    }
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                PlatePhoto(meal: meal, pixels: 1100)
                    .frame(width: 280, height: 280)
                    .frame(maxWidth: .infinity)
                Text(meal.title).font(.custom("Nunito-SemiBold", size: 30, relativeTo: .title))
                if recipe {
                    Text("レシピ").font(.system(size: 14, weight: .bold)).foregroundStyle(clay)
                    if !structured.ingredients.isEmpty {
                        Text("\(servings)人前").font(.subheadline)
                    }
                    RecipeContent(recipe: structured, servings: servings, showsIngredientTags: false)
                    if !meal.recipe.isEmpty {
                        Text(meal.recipe).font(.system(size: 17)).fixedSize(horizontal: false, vertical: true)
                    }
                    if let link { Text(link.absoluteString).font(.footnote) }
                } else {
                    if let date = meal.recordedDate {
                        Text(dayLabel(date)).font(.system(size: 16)).foregroundStyle(ink.opacity(0.66))
                    }
                    if includePlace, let place = meal.place, place.isVenue {
                        Text(place.name).font(.system(size: 16))
                    }
                }
            }
            .foregroundStyle(ink)
            .padding(23).frame(width: 400, alignment: .leading)
            .background { AlbumPaper() }
            .environment(\.locale, AppLanguage.locale)
        )
        renderer.scale = 3
        return renderer.uiImage
    }
}

struct ShareCard: Identifiable {
    let id = UUID()
    let image: UIImage
    let description: String
    let render: @MainActor (Bool) -> UIImage?
}

struct SharePreview: View {
    let card: ShareCard
    @Environment(\.dismiss) private var dismiss
    @State private var showLogo = true
    @State private var renderedImage: UIImage?

    private var image: UIImage { renderedImage ?? card.image }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .clipShape(.rect(cornerRadius: 16))
                        .shadow(color: ink.opacity(0.13), radius: 16, y: 8)
                        .accessibilityLabel(card.description)
                    HStack(spacing: 8) {
                        Text("ロゴ")
                        Toggle("ロゴ", isOn: $showLogo)
                            .labelsHidden()
                            .fixedSize()
                    }
                    .tint(ink)
                }
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                .padding(28)
            }
            .onChange(of: showLogo) { _, _ in updateImage() }
            .background { AlbumPaper().ignoresSafeArea() }
            .safeAreaInset(edge: .bottom) {
                ShareLink(item: Image(uiImage: image), preview: SharePreviewItem) {
                    Text("共有する").font(.system(.body).weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .foregroundStyle(.white)
                }.hapticActivation()
                .buttonStyle(.borderedProminent)
                .tint(clay)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background { AlbumPaper().ignoresSafeArea() }
            }
            .navigationTitle("共有カード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { CrumbHaptics.tap(); dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
    }

    @MainActor private func updateImage() {
        if let updated = card.render(showLogo) { renderedImage = updated }
    }

    private var SharePreviewItem: SwiftUI.SharePreview<Image, Never> {
        SwiftUI.SharePreview(card.description, image: Image(uiImage: image))
    }
}

private struct RecipeReader: View {
    let meal: Meal
    let recipe: MealRecipe
    @Binding var servings: Int
    let link: URL?
    var canEdit = true
    let share: () -> Void
    @State private var section = 0
    @State private var nutrition = false
    @State private var asking = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                MealPhoto(data: meal.photo, size: 200)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityHidden(true)
                Text(meal.title).font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
            }.padding(.horizontal, 20)
            if !recipe.ingredients.isEmpty {
                Stepper("\(servings)人前", value: $servings, in: 1...99)
                    .padding(.horizontal, 20)
            }
            HStack(spacing: 18) {
                Button("View nutrition", systemImage: "leaf") { CrumbHaptics.tap(); nutrition = true }
                Button("Ask Crumb", systemImage: "bubble.left.and.bubble.right") { CrumbHaptics.tap(); asking = true }
            }.font(.subheadline).buttonStyle(.bordered).tint(ink).foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            Picker("レシピの表示", selection: $section) {
                Text("材料").tag(0)
                Text("手順").tag(1)
            }.pickerStyle(.segmented).padding(.horizontal, 20)

            // Keep both scroll views mounted so changing tabs preserves each position.
            ZStack {
                readerPage(ingredients: true)
                    .opacity(section == 0 ? 1 : 0)
                    .allowsHitTesting(section == 0)
                    .accessibilityHidden(section != 0)
                readerPage(ingredients: false)
                    .opacity(section == 1 ? 1 : 0)
                    .allowsHitTesting(section == 1)
                    .accessibilityHidden(section != 1)
            }
        }
        .padding(.top, 12)
        .foregroundStyle(ink)
        .background(paper.ignoresSafeArea())
        .sheet(isPresented: $nutrition) { NutritionView(meal: meal, servings: servings, canEdit: canEdit) }
        .sheet(isPresented: $asking) { AskCrumbView(meal: meal) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("レシピを共有", systemImage: "square.and.arrow.up", action: CrumbHaptics.action(share))
            }
        }
    }

    private var displayedRecipe: MealRecipe {
        var value = recipe
        value.changeServings(to: servings)
        return value
    }

    private func readerPage(ingredients: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if ingredients {
                    if recipe.isMeal {
                        MealDishesView(meal: meal, canEdit: canEdit)
                    } else if !recipe.ingredients.isEmpty {
                        RecipeContent(recipe: displayedRecipe, servings: servings, showsSteps: false, showsIngredientTags: false)
                    } else {
                        Text("材料はまだ登録されていません").foregroundStyle(.secondary)
                    }
                } else {
                    RecipeContent(recipe: displayedRecipe, servings: servings, showsIngredients: false, showsIngredientTags: false)
                    if !meal.recipe.isEmpty { Text(meal.recipe).textSelection(.enabled) }
                    if recipe.steps.isEmpty && meal.recipe.isEmpty {
                        Text("手順はまだ登録されていません").foregroundStyle(.secondary)
                    }
                }
                if let link { Link("レシピのページを開く", destination: link).hapticActivation() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.bottom, 24).padding(.top, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
