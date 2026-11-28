import SwiftUI
import SwiftData

struct MealReviewView: View {
    let proposal: AssistantProposal
    let bookID: String
    let didSave: (Meal) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var cloud: CloudLibrary
    @EnvironmentObject private var plus: PlusStore
    @AppStorage("menuBooks") private var storedBooks = "[]"
    @State private var title: String
    @State private var components: [MealComponent]
    @State private var serves: Int
    @State private var useCover = false
    @State private var error: String?
    @State private var saved = false
    init(proposal: AssistantProposal, bookID: String, didSave: @escaping (Meal) -> Void) {
        self.proposal = proposal; self.bookID = bookID; self.didSave = didSave
        _title = State(initialValue: proposal.draft.title)
        _components = State(initialValue: proposal.components)
        _serves = State(initialValue: proposal.draft.recipe.servings)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Meal name") { TextField("Meal name", text: $title) }
                Section("People") { Stepper("Serves \(serves)", value: $serves, in: 1...99) }
                Section("Dishes") {
                    ForEach($components) { $component in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(component.title).font(.headline)
                            Text(component.recipeID == nil ? "New recipe draft" : "From My Menu").font(.caption).foregroundStyle(secondaryInk)
                            Stepper("\(component.portionPerPerson.formatted()) recipe serving / person", value: $component.portionPerPerson, in: 0.25...4, step: 0.25)
                                .font(.subheadline)
                        }.padding(.vertical, 6)
                    }
                }
                if let bytes = proposal.preview, let image = UIImage(data: bytes) {
                    Section {
                        Image(uiImage: image).resizable().scaledToFit()
                        Text("AI preview").font(.caption).foregroundStyle(secondaryInk)
                        Toggle("Use as cover", isOn: $useCover)
                    }
                }
                Text("Existing recipes are linked. New dishes stay inside this meal until you choose to save them individually.")
                    .font(.footnote).foregroundStyle(secondaryInk)
                if let error { Text(error).foregroundStyle(.red) }
                Button("Save meal") { save() }.disabled(saved || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .scrollContentBackground(.hidden).background(paper).tint(ink)
            .navigationTitle("Review meal").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    private func save() {
        guard !saved, let book = MenuBook.decode(storedBooks).first(where: { $0.id == bookID }),
              PlanPolicy.canEdit(book: cloud.resolved(book), viewer: account.session?.userID, plus: plus.hasPlus) else {
            error = "This menu book is read-only. Save to My Menu instead."; return
        }
        guard let cover = (useCover ? proposal.preview : nil) ?? UIImage(named: "CrumbAvatar")?.pngData() else { return }
        let record = Meal(photo: cover, name: title.trimmingCharacters(in: .whitespacesAndNewlines), date: .now, place: nil)
        var recipe = MealRecipe()
        recipe.servings = serves; recipe.servingsKnown = true
        recipe.mealComponents = components
        recipe.coverIsAI = useCover
        record.structuredRecipe = recipe.contents
        record.menuBookID = bookID == MenuBook.defaultID ? nil : bookID
        context.insert(record)
        do {
            try context.save(); saved = true; CrumbHaptics.success()
            NotificationCenter.default.post(name: .crumbLibraryChanged, object: nil)
            didSave(record); dismiss()
        } catch { context.delete(record); self.error = "Could not save this meal. Your draft is kept." }
    }
}

struct MealDishesView: View {
    let meal: Meal
    var canEdit: Bool
    @Query private var library: [Meal]
    @Environment(\.modelContext) private var context
    @State private var selected: MealComponent?
    @State private var message: String?
    private var components: [MealComponent] { MealRecipe(contents: meal.structuredRecipe).mealComponents ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dishes").font(.custom("Nunito-SemiBold", size: 24))
            ForEach(components) { component in
                Button { selected = component } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(component.title).font(.headline)
                            Text(component.recipeID == nil ? "New recipe" : "Linked recipe").font(.caption).foregroundStyle(secondaryInk)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.foregroundStyle(ink).padding(16).background(ink.opacity(0.035), in: .rect(cornerRadius: 15))
                }.buttonStyle(.plain)
            }
            if let message { Text(message).font(.footnote) }
        }
        .sheet(item: $selected) { component in
            if let id = component.recipeID, let existing = library.first(where: { $0.id == id }) {
                NavigationStack {
                    MealDetail(meal: existing)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { selected = nil } } }
                }
            } else if let draft = component.draft {
                ComponentRecipeView(draft: draft) { record in
                    guard canEdit else { return }
                    var recipe = MealRecipe(contents: meal.structuredRecipe)
                    guard let index = recipe.mealComponents?.firstIndex(where: { $0.id == component.id }) else { return }
                    recipe.mealComponents?[index].recipeID = record.id
                    recipe.mealComponents?[index].draft = nil
                    let before = meal.structuredRecipe
                    meal.structuredRecipe = recipe.contents
                    do { try context.save(); NotificationCenter.default.post(name: .crumbLibraryChanged, object: nil) }
                    catch { meal.structuredRecipe = before; message = "Recipe saved. The meal link could not be updated." }
                }
            } else { Text("This recipe is no longer available.").padding() }
        }
    }
}

private struct ComponentRecipeView: View {
    let draft: RecipeDraft
    let saved: (Meal) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reviewing = false
    @State private var savedRecipe: Meal?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(draft.title).font(.custom("Nunito-SemiBold", size: 28))
                    RecipeContent(recipe: draft.recipe, servings: draft.recipe.servings, showsIngredientTags: false)
                    if !draft.notes.isEmpty { Text(draft.notes) }
                    if savedRecipe == nil {
                        Button("Save individual recipe") { reviewing = true }.buttonStyle(.borderedProminent).tint(ink)
                    } else { Label("Saved to My Menu", systemImage: "checkmark.circle") }
                }.padding(22)
            }.background(paper).navigationTitle("Recipe").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $reviewing) {
                    MealEditor(meal: nil, draft: draft) { record in savedRecipe = record; saved(record) }
                }
        }
    }
}
