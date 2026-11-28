import SwiftUI
import SwiftData

struct NutritionView: View {
    let meal: Meal
    let servings: Int
    var canEdit = false
    @EnvironmentObject private var plus: PlusStore
    @Environment(\.dismiss) private var dismiss
    @State private var paywall = false
    var body: some View {
        NavigationStack {
            Group {
                if plus.hasPlus { NutritionDetail(meal: meal, displayedServings: servings, canEdit: canEdit) }
                else {
                    VStack(spacing: 22) {
                        Image(systemName: "leaf").font(.system(size: 40)).foregroundStyle(ink)
                        Text("See the nutrition in your own recipes.")
                            .font(.custom("Nunito-SemiBold", size: 28)).multilineTextAlignment(.center)
                        Text("Crumb Plus estimates calories, protein, fat and carbs from your ingredients. Ingredient scaling stays free.")
                            .foregroundStyle(secondaryInk).multilineTextAlignment(.center)
                        Button { CrumbHaptics.tap(); paywall = true } label: {
                            Text("Explore Crumb Plus").foregroundStyle(.white)
                        }
                            .buttonStyle(.borderedProminent).tint(ink)
                        Button("Restore purchases") { Task { await plus.restore() } }.disabled(plus.busy)
                        if let message = plus.message { Text(message).font(.footnote) }
                    }.padding(28).frame(maxHeight: .infinity)
                }
            }
            .background(paper).foregroundStyle(ink)
            .navigationTitle("Nutrition").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $paywall) { PlusView() }
        }
    }
}

private struct NutritionDetail: View {
    let meal: Meal
    let displayedServings: Int
    let canEdit: Bool
    @Query private var meals: [Meal]
    @Environment(\.modelContext) private var context
    @State private var recipe: MealRecipe
    @State private var total = false
    @State private var message: String?
    @State private var baseline: String?
    private struct Selection: Identifiable { let id: UUID }
    @State private var selection: Selection?
    init(meal: Meal, displayedServings: Int, canEdit: Bool) {
        self.meal = meal; self.displayedServings = displayedServings; self.canEdit = canEdit
        _recipe = State(initialValue: MealRecipe(contents: meal.structuredRecipe))
        _baseline = State(initialValue: meal.structuredRecipe)
    }
    private var estimate: Nutrition.Estimate { Nutrition.estimate(recipe) }
    private var mealValues: (Nutrients?, [String]) {
        var values: [Nutrients] = [], missing: [String] = []
        for component in recipe.mealComponents ?? [] {
            let value = component.recipeID.flatMap { id in meals.first { $0.id == id } }.map { MealRecipe(contents: $0.structuredRecipe) } ?? component.draft?.recipe
            if let value {
                let estimate = Nutrition.estimate(value)
                if let perPerson = estimate.perPerson { values.append(perPerson.times(component.portionPerPerson)) }
                if estimate.perPerson == nil || !estimate.missing.isEmpty { missing.append(component.title) }
            } else { missing.append(component.title) }
        }
        return (values.isEmpty ? nil : values.reduce(Nutrients(), +), missing)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(recipe.isMeal ? "Nutrition per person" : "Estimated nutrition")
                    .font(.custom("Nunito-SemiBold", size: 27))
                Text(meal.title).font(.headline)
                if !recipe.knowsServings {
                    Text("Set servings to calculate nutrition per person.").foregroundStyle(secondaryInk)
                    Stepper("Set servings: \(recipe.servings)", value: $recipe.servings, in: 1...99)
                    Button("Use these servings") { recipe.servingsKnown = true }
                } else {
                    Picker("Display", selection: $total) {
                        Text("Per person").tag(false)
                        Text("Total for \(displayedServings)").tag(true)
                    }.pickerStyle(.segmented)
                    if let value = recipe.isMeal ? mealValues.0 : estimate.perPerson {
                        nutrientGrid(value.times(total ? Double(displayedServings) : 1))
                    } else {
                        Label("Not enough information to calculate nutrition.", systemImage: "info.circle")
                    }
                }
                Text("Estimates use USDA FoodData Central values. Food type, raw/cooked state and household weights affect results.")
                    .font(.footnote).foregroundStyle(secondaryInk)
                if recipe.isMeal {
                    ForEach(recipe.mealComponents ?? []) { component in
                        HStack {
                            Text(component.title)
                            Spacer()
                            Text("\(component.portionPerPerson.formatted()) serving / person").font(.caption)
                        }
                    }
                    if !mealValues.1.isEmpty {
                        Label("Partially calculated: \(mealValues.1.joined(separator: ", ")) not fully included.", systemImage: "exclamationmark.circle")
                    }
                } else {
                    Text("Ingredients & assumptions").font(.headline)
                    ForEach($recipe.ingredients) { $ingredient in
                        assumptionRow($ingredient)
                    }
                    if !estimate.missing.isEmpty {
                        Text("Partial estimate — only ingredients with a matched food and known weight are included.")
                            .font(.footnote).foregroundStyle(secondaryInk)
                    }
                    if canEdit {
                        Button { save() } label: {
                            Text("Save assumptions").foregroundStyle(.white)
                        }.buttonStyle(.borderedProminent).tint(ink)
                    }
                }
                if let message { Text(message).font(.footnote) }
                Link("FoodData Central data & sources", destination: URL(string: "https://fdc.nal.usda.gov/")!)
            }.padding(22)
        }
        .sheet(item: $selection) { selected in
            FoodMatchPicker { food in
                if let index = recipe.ingredients.firstIndex(where: { $0.id == selected.id }) {
                    recipe.ingredients[index].foodID = food.id
                }
            }
        }
    }
    private func nutrientGrid(_ value: Nutrients) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            nutrient("Calories", value.kcal, "kcal")
            nutrient("Protein", value.protein, "g")
            nutrient("Fat", value.fat, "g")
            nutrient("Carbs", value.carbs, "g")
        }
    }
    private func nutrient(_ label: String, _ value: Double, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(secondaryInk)
            Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                .font(.custom("Nunito-SemiBold", size: 23))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(ink.opacity(0.035), in: .rect(cornerRadius: 16))
    }
    private func assumptionRow(_ ingredient: Binding<RecipeIngredient>) -> some View {
        let line = Nutrition.line(ingredient.wrappedValue)
        return VStack(alignment: .leading, spacing: 9) {
            Text(ingredient.wrappedValue.name).fontWeight(.semibold)
            Button { selection = Selection(id: ingredient.wrappedValue.id) } label: {
                HStack { Text(line.food?.name ?? "Choose food match"); Image(systemName: "chevron.down").font(.caption) }
            }
            if let food = line.food { Link(food.description, destination: food.sourceURL).font(.caption) }
            if let assumption = line.assumption { Text(assumption).font(.footnote).foregroundStyle(secondaryInk) }
            if line.values == nil { Text(line.omission).font(.footnote).foregroundStyle(secondaryInk) }
            HStack {
                Text("Weight for this recipe").font(.subheadline)
                TextField("g", value: ingredient.weightGrams, format: .number)
                    .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("g")
            }
            if let grams = line.grams { Text("Included: \(RecipeQuantity.text(grams)) g").font(.caption) }
        }.padding(14).background(ink.opacity(0.025), in: .rect(cornerRadius: 14))
    }
    private func save() {
        guard canEdit else { return }
        // Avoid overwriting concurrent edits made while the nutrition sheet was open.
        let latest = MealRecipe(contents: meal.structuredRecipe)
        guard meal.structuredRecipe == baseline, latest.ingredients.map(\.id) == recipe.ingredients.map(\.id) else {
            message = "The recipe changed. Reopen nutrition to use the latest ingredients."; return
        }
        var result = latest
        for index in result.ingredients.indices {
            result.ingredients[index].foodID = recipe.ingredients[index].foodID
            result.ingredients[index].weightGrams = recipe.ingredients[index].weightGrams
        }
        result.servings = recipe.servings; result.servingsKnown = recipe.servingsKnown
        let previous = meal.structuredRecipe
        meal.structuredRecipe = result.contents
        do {
            try context.save(); baseline = meal.structuredRecipe; CrumbHaptics.success(); message = "Assumptions saved."
            NotificationCenter.default.post(name: .crumbLibraryChanged, object: nil)
        } catch { meal.structuredRecipe = previous; message = "Could not save. Please retry." }
    }
}

private struct FoodMatchPicker: View {
    let selected: (FoodRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var results: [FoodRecord] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return Array(Nutrition.foods.lazy.filter { food in
            words.isEmpty || words.allSatisfy { food.description.lowercased().contains($0) || food.name.lowercased().contains($0) }
        }.prefix(80))
    }
    var body: some View {
        NavigationStack {
            List(results) { food in
                Button { selected(food); dismiss() } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(food.name).foregroundStyle(ink)
                        Text("USDA \(food.id) · \(food.kcal.formatted()) kcal / 100 g").font(.caption).foregroundStyle(secondaryInk)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search food, raw or cooked")
            .navigationTitle("Food match").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
