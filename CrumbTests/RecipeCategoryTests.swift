import XCTest
@testable import crumb

final class RecipeCategoryTests: XCTestCase {
    func testRenameAndDeleteKeepOtherCategories() {
        XCTAssertEqual(RecipeCategories.replacing("Dinner", with: "Evening", in: ["dinner", "Protein"]), ["Evening", "Protein"])
        XCTAssertEqual(RecipeCategories.replacing("Dinner", with: nil, in: ["DINNER", "Protein"]), ["Protein"])
        XCTAssertEqual(RecipeCategories.replacing("Dinner", with: "dinner", in: ["Dinner"]), ["dinner"])
    }
}
