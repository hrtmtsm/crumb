import Foundation

struct FoodRecord: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let aliases: [String]
    let kcal: Double
    let protein: Double
    let fat: Double
    let carbs: Double
    let countGrams: Double?
    let gramsPerMl: Double?
    var sourceURL: URL { URL(string: "https://fdc.nal.usda.gov/food-details/\(id)/nutrients")! }
}
struct Nutrients: Equatable {
    var kcal = 0.0, protein = 0.0, fat = 0.0, carbs = 0.0
    static func + (a: Self, b: Self) -> Self { Self(kcal: a.kcal+b.kcal, protein: a.protein+b.protein, fat: a.fat+b.fat, carbs: a.carbs+b.carbs) }
    func times(_ factor: Double) -> Self { Self(kcal: kcal*factor, protein: protein*factor, fat: fat*factor, carbs: carbs*factor) }
}
enum Nutrition {
    static let foods: [FoodRecord] = {
        guard let url = Bundle.main.url(forResource: "usda-foods", withExtension: "json"),
              let bytes = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FoodRecord].self, from: bytes)) ?? []
    }()
    private static let byID = Dictionary(foods.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    private static let byAlias = Dictionary(foods.flatMap { food in food.aliases.map { ($0, food) } }, uniquingKeysWith: { first, _ in first })
    struct Line: Identifiable {
        let ingredient: RecipeIngredient
        let food: FoodRecord?
        let grams: Double?
        let assumption: String?
        var id: UUID { ingredient.id }
        var values: Nutrients? {
            guard let food, let grams, grams.isFinite, grams > 0 else { return nil }
            return Nutrients(kcal: food.kcal, protein: food.protein, fat: food.fat, carbs: food.carbs).times(grams/100)
        }
        var omission: String {
            if ingredient.name.lowercased().contains("oil") { return "Oil not included — add an amount." }
            return food == nil ? "Choose a food match." : "Add an amount or weight."
        }
    }
    struct Estimate {
        let lines: [Line]
        let perPerson: Nutrients?
        var missing: [Line] { lines.filter { $0.values == nil } }
    }
    static func line(_ ingredient: RecipeIngredient) -> Line {
        let name = ingredient.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let food = ingredient.foodID.flatMap { byID[$0] } ?? byAlias[name]
        if let grams = ingredient.weightGrams, grams.isFinite, grams > 0 {
            return Line(ingredient: ingredient, food: food, grams: grams, assumption: "Using your entered weight.")
        }
        guard let amount = ingredient.amount, amount.isFinite, amount > 0 else {
            return Line(ingredient: ingredient, food: food, grams: nil, assumption: nil)
        }
        let unit = ingredient.unit.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var grams: Double?, assumption: String?
        switch unit {
        case "g", "gram", "grams": grams = amount
        case "kg": grams = amount*1000
        case "mg": grams = amount/1000
        case "oz": grams = amount*28.3495
        case "lb", "lbs": grams = amount*453.592
        case "ml", "l", "tsp", "tbsp", "cup", "cups":
            if let density = food?.gramsPerMl {
                let ml = unit == "tsp" ? 5.0 : unit == "tbsp" ? 15.0 : unit == "l" ? 1000.0 : unit.hasPrefix("cup") ? 240.0 : 1.0
                grams = amount*ml*density
                assumption = "Standard volume and density assumed. Confirm the weight."
            }
        case "", "piece", "pieces", "clove", "cloves", "個", "玉", "本", "片":
            if let weight = food?.countGrams {
                grams = amount*weight
                assumption = "Assuming \(RecipeQuantity.text(weight)) g per item. Confirm or edit."
            }
        default: break
        }
        return Line(ingredient: ingredient, food: food, grams: grams, assumption: assumption)
    }
    static func estimate(_ recipe: MealRecipe) -> Estimate {
        let lines = recipe.cleaned.ingredients.map(line)
        let known = lines.compactMap(\.values)
        let perPerson = !recipe.knowsServings || known.isEmpty ? nil : known.reduce(Nutrients(), +).times(1/Double(max(1, recipe.servings)))
        return Estimate(lines: lines, perPerson: perPerson)
    }
}
