import Foundation

/// Stored inside structuredRecipe, so older SwiftData stores need no destructive migration.
struct RecipeDraft: Codable, Identifiable {
    var id = UUID()
    var title: String
    var recipe: MealRecipe
    var notes = ""
    var source: String?
    var originRecipeID: UUID?
    var changes: String?
    var imagePrompt: String?
    var previewData: Data?
}

struct MealComponent: Codable, Identifiable {
    var id = UUID()
    var recipeID: UUID?
    var draft: RecipeDraft?
    var title: String
    /// Recipe servings allocated to one person, not the whole recipe's yield.
    var portionPerPerson = 1.0
}

extension MealRecipe {
    var knowsServings: Bool { servingsKnown != false }
    var isMeal: Bool { !(mealComponents ?? []).isEmpty }
    var cleaned: Self {
        var result = self
        for ingredient in result.ingredients where ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.removeIngredient(ingredient.id)
        }
        for index in result.steps.indices.reversed() where result.steps[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.removeStep(at: index)
        }
        return result
    }
}

enum RecipeQuantity {
    static func parse(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "½", with: " 1/2").replacingOccurrences(of: "¼", with: " 1/4")
            .replacingOccurrences(of: "¾", with: " 3/4").trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        let parts = text.split(separator: " ")
        if parts.count == 2, let a = Double(parts[0]), let b = parse(String(parts[1])) { return a + b }
        let ratio = text.split(separator: "/")
        let value: Double?
        if ratio.count == 2, let a = Double(ratio[0]), let b = Double(ratio[1]), b > 0 { value = a / b }
        else { value = Double(text.replacingOccurrences(of: ",", with: ".")) }
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    static func text(_ amount: Double?) -> String {
        guard let amount else { return "" }
        return amount.formatted(.number.precision(.fractionLength(0...3)).locale(Locale(identifier: "en_US")))
    }
}
