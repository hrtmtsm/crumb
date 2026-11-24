import SwiftUI
import SwiftData

struct MealDetail: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletion = false
    @State private var deletionFailed = false
    let meal: Meal
    var canEdit = true
    @State private var editing = false
    @State private var viewingRecipe = false
    @State private var shareAfterRecipe = false
    @State private var servingOverride: Int?

    private var structured: MealRecipe { MealRecipe(contents: meal.structuredRecipe) }
    private var hasRecipe: Bool { !structured.isEmpty || !meal.recipe.isEmpty || link != nil }
    private var servings: Int { servingOverride ?? structured.servings }

    @State private var shareCard: ShareCard?
    @State private var shareError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MealPhoto(data: meal.photo, size: 1250)
                    .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 9) {
                    Text(meal.title).font(.system(.largeTitle)).bold()
                        .accessibilityAddTraits(.isHeader)
                    if let date = meal.recordedDate {
                        Text(dayLabel(date)).foregroundStyle(clay)
                    }
                    if !meal.note.isEmpty { Text(meal.note).padding(.top, 5) }
                    IngredientTagLayout(spacing: 7) {
                        ForEach(meal.categories, id: \.self) { category in
                            Text(verbatim: category).font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(ink.opacity(0.06), in: .capsule)
                        }
                    }

                }
                if hasRecipe {
                    Divider()
                    Button { viewingRecipe = true } label: {
                        Label("レシピを見る", systemImage: "book")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                }
                Menu {
                    Button("料理写真を共有", systemImage: "photo") { share(recipe: false) }
                    if hasRecipe {
                        Button("レシピを共有", systemImage: "book") { share(recipe: true) }
                    }
                } label: {
                    Label("共有", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }.buttonStyle(.borderedProminent).tint(ink)

            }
            .padding(24)
        }
        .foregroundStyle(ink)
        .background(paper.ignoresSafeArea())
        .navigationTitle("レシピ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if canEdit {
                Menu("操作", systemImage: "ellipsis.circle") {
                    if meal.wantToVisit != true { Button("編集", systemImage: "pencil") { editing = true } }
                    Button("料理を削除", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                }
            }
        }
        .confirmationDialog("この料理を削除しますか？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                do {
                    context.delete(meal)
                    try context.save()
                    dismiss()
                } catch {
                    context.rollback()
                    deletionFailed = true
                }
            }
        } message: {
            Text("この端末の記録を削除します。共有済みの記録は残ります。")
        }
        .alert("料理を削除できませんでした", isPresented: $deletionFailed) {
            Button("閉じる", role: .cancel) {}
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
                ), link: link) {
                    shareAfterRecipe = true
                    viewingRecipe = false
                }
                .navigationTitle("レシピ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { viewingRecipe = false }
                    }
                }
            }
        }
        .sheet(isPresented: $editing) { MealEditor(meal: meal) }
        .sheet(item: $shareCard) { SharePreview(card: $0) }
        .alert("カードを作成できませんでした", isPresented: $shareError) {
            Button("閉じる", role: .cancel) {}
        }
    }

    private var link: URL? {
        guard let url = URL(string: meal.recipeURL),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    @MainActor private func share(recipe: Bool, includePlace: Bool = false) {
        let renderer = ImageRenderer(content:
            VStack(alignment: .leading, spacing: 19) {
                Text("crumb").font(crumbFont(22)).foregroundStyle(ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PlatePhoto(meal: meal, pixels: 1100)
                    .frame(width: 280, height: 280)
                    .frame(maxWidth: .infinity)
                Text(meal.title).font(.system(size: 30, weight: .semibold))
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
        )
        renderer.scale = 3
        if let image = renderer.uiImage {
            shareCard = ShareCard(image: image, description: meal.title)
        } else {
            shareError = true
        }
    }
}

struct ShareCard: Identifiable {
    let id = UUID()
    let image: UIImage
    let description: String
}

struct SharePreview: View {
    let card: ShareCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Image(uiImage: card.image)
                    .resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: 16))
                    .shadow(color: ink.opacity(0.13), radius: 16, y: 8)
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity)
                    .padding(28)
                    .accessibilityLabel(card.description)
            }
            .background { AlbumPaper().ignoresSafeArea() }
            .safeAreaInset(edge: .bottom) {
                ShareLink(item: Image(uiImage: card.image), preview: SharePreviewItem) {
                    Text("共有する").font(.system(.body).weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(clay)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background { AlbumPaper().ignoresSafeArea() }
            }
            .navigationTitle("共有カード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var SharePreviewItem: SwiftUI.SharePreview<Image, Never> {
        SwiftUI.SharePreview(card.description, image: Image(uiImage: card.image))
    }
}

private struct RecipeReader: View {
    let meal: Meal
    let recipe: MealRecipe
    @Binding var servings: Int
    let link: URL?
    let share: () -> Void
    @State private var section = 0

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("レシピを共有", systemImage: "square.and.arrow.up", action: share)
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
                    if !recipe.ingredients.isEmpty {
                        ForEach(recipe.ingredients) { ingredient in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(ingredient.name).frame(maxWidth: .infinity, alignment: .leading)
                                Text(ingredient.quantity(multiplier: Double(servings) / Double(recipe.servings)))
                                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white, in: .rect(cornerRadius: 16))
                        }
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
                if let link { Link("レシピのページを開く", destination: link) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.bottom, 24).padding(.top, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
