import XCTest
import SwiftData
@testable import crumb

final class RecipeAssistantTests: XCTestCase {
    func testBundledFoodDatabaseIncludesSearchableUSDARecords() {
        XCTAssertGreaterThan(Nutrition.foods.count, 7000)
        XCTAssertNotNil(Nutrition.foods.first { $0.description.lowercased().contains("broccoli") })
        XCTAssertTrue(Nutrition.foods.allSatisfy { $0.kcal.isFinite && $0.protein.isFinite && $0.fat.isFinite && $0.carbs.isFinite })
    }
    func testLegacyRecipeDecodesAndFreeTextNumbersNeverScale() throws {
        let id = UUID()
        let old = """
        {"servings":2,"ingredients":[{"id":"\(id.uuidString)","name":"chicken breast","amount":200,"unit":"g"}],"steps":["Cook for 10 minutes at 180 C."],"stepIngredients":[["\(id.uuidString)"]]}
        """
        let original = MealRecipe(contents: old)
        var displayed = original
        displayed.changeServings(to: 4)
        XCTAssertEqual(original.servings, 2)
        XCTAssertEqual(original.ingredients[0].amount, 200)
        XCTAssertEqual(displayed.ingredients[0].amount, 400)
        XCTAssertEqual(displayed.steps, ["Cook for 10 minutes at 180 C."])
        XCTAssertEqual(displayed.linkedIngredients(for: 0)[0].amount, 400)
        XCTAssertNotNil(MealRecipe(contents: displayed.contents).contents)
    }
    func testFractionsCountsAndToTasteRoundTrip() throws {
        XCTAssertEqual(RecipeQuantity.parse("½"), 0.5)
        XCTAssertEqual(RecipeQuantity.parse("1¼"), 1.25)
        XCTAssertEqual(RecipeQuantity.parse("3/4"), 0.75)
        XCTAssertNil(RecipeQuantity.parse("1/0"))
        var value = MealRecipe()
        value.ingredients = [RecipeIngredient(name: "egg", amount: 2, unit: ""), RecipeIngredient(name: "salt", unit: "To taste")]
        value.steps = ["Simmer for 15 minutes."]
        value.changeServings(to: 2)
        XCTAssertEqual(value.ingredients[0].amount, 4)
        XCTAssertEqual(value.ingredients[1].quantity(multiplier: 2), "To taste")
        XCTAssertEqual(value.steps[0], "Simmer for 15 minutes.")
    }
    func testNutritionIsPerPersonAndPartialDoesNotBecomeZero() throws {
        var recipe = MealRecipe(); recipe.servings = 2
        recipe.ingredients = [RecipeIngredient(name: "chicken breast", amount: 200, unit: "g"), RecipeIngredient(name: "olive oil", unit: "")]
        let result = Nutrition.estimate(recipe)
        XCTAssertEqual(try XCTUnwrap(result.perPerson).kcal, 120, accuracy: 0.1)
        XCTAssertEqual(result.missing.count, 1)
        XCTAssertTrue(result.missing[0].omission.contains("Oil not included"))
        var scaled = recipe; scaled.changeServings(to: 4)
        XCTAssertEqual(Nutrition.estimate(scaled).perPerson, result.perPerson)
        recipe.ingredients.removeFirst()
        XCTAssertNil(Nutrition.estimate(recipe).perPerson)
        recipe.servingsKnown = false
        XCTAssertNil(Nutrition.estimate(recipe).perPerson)
    }
    func testOnionWeightAssumptionCanBeOverridden() throws {
        var onion = RecipeIngredient(name: "onion", amount: 1, unit: "")
        XCTAssertEqual(Nutrition.line(onion).grams, 110)
        XCTAssertNotNil(Nutrition.line(onion).assumption)
        onion.weightGrams = 150
        XCTAssertEqual(Nutrition.line(onion).grams, 150)
    }
    func testUnknownServingsAndMealReferencesPersist() throws {
        var source = MealRecipe(); source.servingsKnown = false
        let existing = UUID()
        var meal = MealRecipe()
        meal.mealComponents = [MealComponent(recipeID: existing, title: "Oyakodon"), MealComponent(draft: RecipeDraft(title: "Tofu soup", recipe: source), title: "Tofu soup")]
        let result = MealRecipe(contents: meal.contents)
        XCTAssertTrue(result.isMeal)
        XCTAssertEqual(result.mealComponents?.count, 2)
        XCTAssertEqual(result.mealComponents?[0].recipeID, existing)
        XCTAssertNil(result.mealComponents?[0].draft)
        XCTAssertFalse(MealRecipe(contents: source.contents).knowsServings)
    }
    func testAIReferencesAreValidatedAndOriginalRemainsSeparate() throws {
        let wire = AssistantWireRecipe(title: "Tofu bowl", servings: 2,
            ingredients: [.init(name: "firm tofu", amount: 300, unit: "g")],
            steps: [.init(text: "Pan-fry for 8 minutes.", ingredientIndices: [0])], notes: "")
        let origin = UUID()
        let draft = try wire.draft(origin: origin)
        XCTAssertEqual(draft.recipe.originRecipeID, origin)
        XCTAssertEqual(draft.recipe.linkedIngredients(for: 0).first?.name, "firm tofu")
        var invalid = wire
        invalid.steps = [.init(text: "Cook.", ingredientIndices: [7])]
        XCTAssertThrowsError(try invalid.draft())
    }
    @MainActor func testMealAndVariationPersistWithoutDuplicatingExistingRecipes() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Meal.self, HomePlate.self, configurations: config)
        let context = ModelContext(container)
        let original = Meal(photo: Data(), name: "Chicken bowl", date: .now, place: nil)
        var recipe = MealRecipe(); recipe.ingredients = [RecipeIngredient(name: "chicken breast", amount: 200, unit: "g")]
        original.structuredRecipe = recipe.contents; context.insert(original)
        let variant = Meal(photo: Data(), name: "Tofu bowl", date: .now, place: nil)
        var adapted = recipe; adapted.originRecipeID = original.id
        adapted.ingredients[0].name = "firm tofu"
        variant.structuredRecipe = adapted.contents; context.insert(variant)
        let dinner = Meal(photo: Data(), name: "Chicken dinner", date: .now, place: nil)
        var composition = MealRecipe(); composition.mealComponents = [MealComponent(recipeID: original.id, title: original.title)]
        dinner.structuredRecipe = composition.contents; context.insert(dinner)
        try context.save()
        let saved = try context.fetch(FetchDescriptor<Meal>())
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(MealRecipe(contents: original.structuredRecipe).ingredients[0].name, "chicken breast")
        XCTAssertEqual(MealRecipe(contents: dinner.structuredRecipe).mealComponents?[0].recipeID, original.id)
    }
}
