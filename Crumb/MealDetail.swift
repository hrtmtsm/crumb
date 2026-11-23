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
                if meal.wantToVisit == true {
                    Label("行きたい", systemImage: "bookmark.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(clay)
                    if let source = meal.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Label("Instagramの投稿を見る", systemImage: "arrow.up.right.square")
                        }
                    }
                } else {
                MealPhoto(data: meal.photo, size: 1250)
                    .aspectRatio(1, contentMode: .fit).clipShape(.rect(cornerRadius: 24))
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text(meal.title).font(.system(.largeTitle)).bold()
                        .accessibilityAddTraits(.isHeader)
                    if let date = meal.recordedDate {
                        Text(dayLabel(date)).foregroundStyle(clay)
                    }
                    if let place = meal.place {
                        Label(place.name, systemImage: place.coordinate == nil ? "house" : "mappin")
                            .font(.system(.subheadline))
                    }
                    if !meal.note.isEmpty { Text(meal.note).padding(.top, 5) }
                }
                if hasRecipe {
                    Divider()
                    Button { viewingRecipe = true } label: {
                        Label("レシピを見る", systemImage: "book")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                }
                if meal.wantToVisit != true {
                Menu {
                    Button("食べた思い出") { share(recipe: false) }
                    if meal.place?.isVenue == true {
                        Button("食べた思い出（店名あり）") { share(recipe: false, includePlace: true) }
                    }
                    if hasRecipe { Button("レシピ") { share(recipe: true) } }
                } label: {
                    Label("カードを共有", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .foregroundStyle(ink)
        .background(paper.ignoresSafeArea())
        .navigationTitle("食事の記録")
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(meal.title).font(.title.bold())
                        if !structured.ingredients.isEmpty {
                            Stepper("\(servings)人前", value: Binding(
                                get: { servings }, set: { servingOverride = $0 }
                            ), in: 1...99)
                        }
                        RecipeContent(recipe: structured, servings: servings)
                        if !meal.recipe.isEmpty { Text(meal.recipe).textSelection(.enabled) }
                        if let link { Link("レシピのページを開く", destination: link) }
                        Button("レシピカードを作る", systemImage: "square.and.arrow.up") {
                            shareAfterRecipe = true
                            viewingRecipe = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                }
                .background(paper.ignoresSafeArea())
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
                    RecipeContent(recipe: structured, servings: servings)
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
