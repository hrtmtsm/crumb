import SwiftUI

struct RecipeIngredient: Codable, Identifiable {
    var id = UUID()
    let name: String
    var amount: Double?
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
    var stepIngredients: [[UUID]]?

    func linkedIngredients(for step: Int) -> [RecipeIngredient] {
        guard let links = stepIngredients, links.indices.contains(step) else { return [] }
        return links[step].compactMap { id in ingredients.first { $0.id == id } }
    }
    mutating func link(_ id: UUID, to step: Int) {
        guard steps.indices.contains(step), ingredients.contains(where: { $0.id == id }) else { return }
        var links = stepIngredients ?? []
        while links.count < steps.count { links.append([]) }
        if !links[step].contains(id) { links[step].append(id) }
        stepIngredients = links
    }
    mutating func unlink(_ id: UUID, from step: Int) {
        guard var links = stepIngredients, links.indices.contains(step) else { return }
        links[step].removeAll { $0 == id }
        stepIngredients = links
    }
    mutating func removeStep(at index: Int) {
        guard steps.indices.contains(index) else { return }
        steps.remove(at: index)
        if var links = stepIngredients, links.indices.contains(index) {
            links.remove(at: index); stepIngredients = links
        }
    }
    mutating func changeServings(to count: Int) {
        let next = min(99, max(1, count))
        guard next != servings else { return }
        let multiplier = Double(next) / Double(servings)
        var replacements: [(String, String)] = []
        for index in ingredients.indices {
            let old = [ingredients[index].name, ingredients[index].quantity(multiplier: 1)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            if let amount = ingredients[index].amount { ingredients[index].amount = amount * multiplier }
            let new = [ingredients[index].name, ingredients[index].quantity(multiplier: 1)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            if old != new { replacements.append((old, new)) }
        }
        // Replace all matching inserted ingredient phrases in one pass, avoiding cascaded replacements.
        for index in steps.indices {
            let source = steps[index]
            var result = ""
            var cursor = source.startIndex
            let ordered = replacements.sorted { $0.0.count > $1.0.count }
            while cursor < source.endIndex {
                if let match = ordered.first(where: { source[cursor...].hasPrefix($0.0) }) {
                    result += match.1
                    cursor = source.index(cursor, offsetBy: match.0.count)
                } else {
                    result.append(source[cursor]); cursor = source.index(after: cursor)
                }
            }
            steps[index] = result
        }
        servings = next
    }
    mutating func moveStep(from source: Int, to destination: Int) {
        guard steps.indices.contains(source), steps.indices.contains(destination), source != destination else { return }
        var links = stepIngredients ?? []
        while links.count < steps.count { links.append([]) }
        let text = steps.remove(at: source)
        let materials = links.remove(at: source)
        steps.insert(text, at: destination)
        links.insert(materials, at: destination)
        stepIngredients = links
    }
    mutating func removeIngredient(_ id: UUID) {
        ingredients.removeAll { $0.id == id }
        stepIngredients = stepIngredients?.map { links in links.filter { $0 != id } }
    }


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
    var showsIngredients = true
    var showsSteps = true
    @State private var name = ""
    @State private var amount = ""
    @State private var unit = ""
    @FocusState private var focusedStep: Int?

    private var parsedAmount: Double? {
        if let value = Double(amount.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 {
            return value
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsIngredients {
            Text("材料").font(.subheadline.weight(.semibold))
            IngredientTagLayout(spacing: 7) {
                ForEach(recipe.ingredients) { ingredient in
                    Button {
                        recipe.removeIngredient(ingredient.id)
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
            }
            if showsSteps {
            Text("手順").font(.subheadline.weight(.semibold))
            ForEach(recipe.steps.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top) {
                        Menu {
                            Button("上へ移動", systemImage: "arrow.up") {
                                recipe.moveStep(from: index, to: index - 1)
                            }.disabled(index == 0)
                            Button("下へ移動", systemImage: "arrow.down") {
                                recipe.moveStep(from: index, to: index + 1)
                            }.disabled(index == recipe.steps.count - 1)
                        } label: {
                            VStack(spacing: 5) {
                                Text("\(index + 1).").monospacedDigit()
                                Image(systemName: "line.3.horizontal").font(.caption)
                            }.frame(minWidth: 32, minHeight: 44)
                        }.accessibilityLabel("手順\(index + 1)の順番を変更")
                        VStack(alignment: .leading, spacing: 7) {
                        TextField("手順を入力", text: $recipe.steps[index], axis: .vertical)
                            .focused($focusedStep, equals: index)
                            .padding(12).background(.white, in: .rect(cornerRadius: 15))
                            .overlay(RoundedRectangle(cornerRadius: 15).stroke(ink.opacity(0.10)))
                    if focusedStep == index {
                    IngredientTagLayout(spacing: 6) {
                        ForEach(recipe.ingredients) { ingredient in
                            Button {
                                let text = [ingredient.name, ingredient.quantity(multiplier: 1)]
                                    .filter { !$0.isEmpty }.joined(separator: " ")
                                let current = recipe.steps[index]
                                let separator = current.isEmpty || current.last?.isWhitespace == true ? "" : " "
                                recipe.steps[index] += separator + text
                                focusedStep = index
                            } label: {
                                Text([ingredient.name, ingredient.quantity(multiplier: 1)]
                                    .filter { !$0.isEmpty }.joined(separator: " "))
                                    .font(.caption).padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(.white, in: .capsule)
                                    .overlay(Capsule().stroke(ink.opacity(0.16), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("この手順に材料名と分量を入力")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                        }
                        Button {
                            recipe.removeStep(at: index)
                        } label: {
                            Image(systemName: "minus.circle").frame(width: 34, height: 36)
                        }
                        .accessibilityLabel("手順\(index + 1)を削除")
                    }


                }
            }
            Button("手順を追加", systemImage: "plus") { recipe.steps.append("") }
            }
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
    var showsIngredients = true
    var showsSteps = true
    var showsIngredientTags = true

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if showsIngredients && !recipe.ingredients.isEmpty {
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
            if showsSteps && !recipe.steps.isEmpty {
                Text("作り方").font(.headline)
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1).").fontWeight(.semibold)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                        if showsIngredientTags {
                        IngredientTagLayout(spacing: 6) {
                            ForEach(recipe.ingredients) { ingredient in
                                Text([ingredient.name, ingredient.quantity(multiplier: Double(servings) / Double(recipe.servings))]
                                    .filter { !$0.isEmpty }.joined(separator: " "))
                                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(ink.opacity(0.04), in: .capsule)
                                    .overlay(Capsule().stroke(ink.opacity(0.12), lineWidth: 0.7))
                            }
                        }.padding(.leading, 22)
                        }
                    }
                }
            }
        }
    }
}


// Pack ingredient chips by their intrinsic width instead of fixed-width grid cells.
struct IngredientTagLayout: Layout {
    var spacing: CGFloat = 7
    struct Arrangement {
        var positions: [CGPoint]
        var size: CGSize
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> Arrangement {
        let limit = max(1, width)
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for view in subviews {
            let natural = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(natural.width, limit), height: nil))
            if x > 0 && x + size.width > limit {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return Arrangement(positions: points, size: CGSize(width: usedWidth, height: subviews.isEmpty ? 0 : y + rowHeight))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        return arrange(width: width, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            let width = min(view.sizeThatFits(.unspecified).width, bounds.width)
            view.place(at: CGPoint(x: bounds.minX + layout.positions[index].x, y: bounds.minY + layout.positions[index].y),
                       anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
        }
    }
}
