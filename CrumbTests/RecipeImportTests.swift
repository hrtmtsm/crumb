import XCTest
@testable import crumb

final class RecipeImportTests: XCTestCase {
    func testNestedRecipeSectionsAndQuantities() throws {
        let html = #"""
        <script type="application/ld+json">{"@graph":[{"@type":"WebPage"},{"@type":["Recipe"],"recipeYield":"2 servings","recipeIngredient":["200 g chicken thigh","1/2 onion","soy sauce 1 tbsp","salt to taste"],"recipeInstructions":[{"@type":"HowToSection","name":"Cook","itemListElement":[{"@type":"HowToStep","text":"Fry &amp; stir."},{"@type":"HowToStep","text":"Serve."}]}]}]}</script>
        """#
        let recipe = try RecipeImport.fromHTML(html)
        XCTAssertEqual(recipe.servings, 2)
        XCTAssertEqual(recipe.ingredients.count, 4)
        XCTAssertEqual(recipe.ingredients[0].name, "chicken thigh")
        XCTAssertEqual(recipe.ingredients[0].amount, 200)
        XCTAssertEqual(recipe.ingredients[0].unit, "g")
        XCTAssertEqual(recipe.ingredients[1].amount, 0.5)
        XCTAssertEqual(recipe.ingredients[2].unit, "tbsp")
        XCTAssertEqual(recipe.ingredients[3].name, "salt to taste")
        XCTAssertNil(recipe.ingredients[3].amount)
        XCTAssertEqual(recipe.steps, ["Fry & stir.", "Serve."])
    }
    func testYieldOfPancakesIsNotServings() throws {
        let html = #"<script type="application/ld+json">{"@type":"Recipe","recipeYield":["12","Makes 12 pancakes"],"recipeIngredient":["100 g flour"]}</script>"#
        XCTAssertEqual(try RecipeImport.fromHTML(html).servings, 1)
    }
    func testUnsupportedPageDoesNotInventRecipe() {
        XCTAssertThrowsError(try RecipeImport.fromHTML("<html>A cooking video with no recipe data.</html>"))
        XCTAssertFalse(RecipeImport.allowed(URL(string: "http://example.com")!))
        XCTAssertFalse(RecipeImport.allowed(URL(string: "https://127.0.0.1")!))
        XCTAssertFalse(RecipeImport.allowed(URL(string: "https://test.local")!))
    }
    func testTextAndScalingPreserveEditableIngredients() {
        var recipe = RecipeImport.fromText("卵 2個\n200 g chicken\n", ingredients: true)
        XCTAssertEqual(recipe.ingredients[0].name, "卵")
        XCTAssertEqual(recipe.ingredients[0].amount, 2)
        recipe.ingredients[0].name = "たまご"
        recipe.ingredients[0].unit = "個"
        recipe.changeServings(to: 2)
        XCTAssertEqual(recipe.ingredients[0].amount, 4)
        XCTAssertEqual(RecipeImport.fromText("Mix.\nCook.", ingredients: false).steps, ["Mix.", "Cook."])
    }
}
