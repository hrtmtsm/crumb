import SwiftUI

struct RecipeIngredient: Codable, Identifiable {
    var id = UUID()
    let name: String
    let amount: Double?
    let unit: String

    func quantity(multiplier: Double) -> String {
        guard let amount else { return unit }
        let value = (amount * multiplier).formatted(.number.precision(.fractionLength(0...3)))
        return unit.isEmpty ? value : "\(value) \(unit)"
    }
}

struct MealRecipe: Codable {
    var servings = 2
    var ingredients: [RecipeIngredient] = []
    var steps: [String] = []

    var isEmpty: Bool { ingredients.isEmpty && steps.isEmpty }

    init() {}

    init(contents: String?) {
        if let contents, let data = contents.data(using: .utf8),
           let recipe = try? JSONDecoder().decode(Self.self, from: data) {
            self = recipe
            servings = min(99, max(1, recipe.servings))
        }
    }

    var contents: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard !isEmpty, let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

struct MealRecipeEditor: View {
    @Binding var recipe: MealRecipe
    @State private var name = ""
    @State private var amount = ""
    @State private var unit = ""

    private var parsedAmount: Double? {
        if let value = Double(amount.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 {
            return value
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper("分量の基準  \(recipe.servings)人前", value: $recipe.servings, in: 1...99)
            Text("材料").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)], alignment: .leading) {
                ForEach(recipe.ingredients) { ingredient in
                    Button {
                        recipe.ingredients.removeAll { $0.id == ingredient.id }
                    } label: {
                        HStack {
                            Text([ingredient.name, ingredient.quantity(multiplier: 1)]
                                .filter { !$0.isEmpty }.joined(separator: " "))
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(ink.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("材料を削除")
                }
            }
            TextField("材料名", text: $name).textFieldStyle(.roundedBorder)
                .submitLabel(.done).onSubmit(addIngredient)
            HStack {
                TextField("量", text: $amount).textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                TextField("単位・適量など", text: $unit).textFieldStyle(.roundedBorder)
                Button("追加", action: addIngredient)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (!amount.isEmpty && parsedAmount == nil))
            }
            Text("手順").font(.subheadline.weight(.semibold))
            ForEach(recipe.steps.indices, id: \.self) { index in
                HStack(alignment: .top) {
                    Text("\(index + 1).").monospacedDigit().padding(.top, 5)
                    TextField("手順を入力", text: $recipe.steps[index], axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        recipe.steps.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle").frame(width: 34, height: 36)
                    }
                    .accessibilityLabel("手順\(index + 1)を削除")
                }
            }
            Button("手順を追加", systemImage: "plus") { recipe.steps.append("") }
        }
    }

    private func addIngredient() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, amount.isEmpty || parsedAmount != nil else { return }
        recipe.ingredients.append(RecipeIngredient(name: cleanName, amount: parsedAmount,
                                                   unit: unit.trimmingCharacters(in: .whitespacesAndNewlines)))
        name = ""
        amount = ""
        unit = ""
    }
}

struct RecipeContent: View {
    let recipe: MealRecipe
    let servings: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !recipe.ingredients.isEmpty {
                Text("材料").font(.headline)
                ForEach(recipe.ingredients) { ingredient in
                    HStack(alignment: .firstTextBaseline) {
                        Text(ingredient.name)
                        Spacer(minLength: 12)
                        Text(ingredient.quantity(multiplier: Double(servings) / Double(recipe.servings)))
                            .foregroundStyle(ink.opacity(0.75))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            if !recipe.steps.isEmpty {
                Text("作り方").font(.headline)
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).").fontWeight(.semibold)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
