import XCTest
@testable import crumb

@MainActor
private final class AssistantFixture: AssistantServing {
    var response: AssistantReply
    var intent = "variation"
    var delay: UInt64 = 0
    var imageFails = true
    init(_ response: AssistantReply) { self.response = response }
    func classify(_ text: String, context: AssistantContext, account: AccountStore) async throws -> String { intent }
    func reply(_ text: String, context: AssistantContext, account: AccountStore) async throws -> AssistantReply {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return response
    }
    func image(for proposal: AssistantProposal, account: AccountStore) async throws -> Data {
        if imageFails { throw AssistantFailure.status(503) }
        return Data([1,2,3])
    }
}

@MainActor
final class AskCrumbSessionTests: XCTestCase {
    private var recipe: AssistantWireRecipe { .init(title: "Tofu bowl", servings: 2, ingredients: [.init(name: "firm tofu", amount: 300, unit: "g")], steps: [.init(text: "Pan-fry for 8 minutes.", ingredientIndices: [0])], notes: "") }
    func testImageFailureKeepsEditableProposalAndContext() async throws {
        let source = Meal(photo: Data(), name: "Chicken bowl", date: .now, place: nil)
        let provider = AssistantFixture(.init(message: "Here is a tofu version.", kind: "variation", recipe: recipe, dishes: [], changes: "Chicken replaced with tofu."))
        let session = AskCrumbSession(provider: provider)
        session.configure(meal: source, account: AccountStore())
        session.send("Use tofu.", intent: nil, meal: source, library: [source], account: AccountStore())
        for _ in 0..<50 where session.phase != nil { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(30))
        let proposal = try XCTUnwrap(session.turns.last?.proposal)
        XCTAssertEqual(proposal.draft.recipe.originRecipeID, source.id)
        XCTAssertEqual(proposal.draft.recipe.ingredients.first?.name, "firm tofu")
        XCTAssertNotNil(proposal.previewError)
        XCTAssertNil(session.phase)
        XCTAssertEqual(source.name, "Chicken bowl")
        session.close()
        UserDefaults.standard.removeObject(forKey: "ask-crumb." + source.id.uuidString)
    }
    func testSingleNestedVariationIsAcceptedWithoutAcceptingExistingDishAsDraft() async throws {
        let source = Meal(photo: Data(), name: "Chicken curry", date: .now, place: nil)
        let reply = AssistantReply(message: "Tofu instead.", kind: "variation", dishes: [
            .init(recipe: recipe, title: recipe.title, portionPerPerson: 1)], changes: "Tofu substituted.")
        let session = AskCrumbSession(provider: AssistantFixture(reply))
        session.configure(meal: source, account: AccountStore())
        session.send("Use tofu.", intent: "variation", meal: source, library: [source], account: AccountStore())
        for _ in 0..<50 where session.phase != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(session.error)
        XCTAssertEqual(session.turns.last?.proposal?.draft.recipe.ingredients.first?.name, "firm tofu")
        XCTAssertEqual(session.turns.last?.proposal?.draft.recipe.originRecipeID, source.id)
        var linked = reply
        linked.dishes[0].existingRecipeID = source.id.uuidString
        XCTAssertNil(linked.resolvedRecipe)
        session.close()
        UserDefaults.standard.removeObject(forKey: "ask-crumb." + source.id.uuidString)
    }
    func testCancelStopsWaitingAndPreservesConversation() async throws {
        let source = Meal(photo: Data(), name: "Soup", date: .now, place: nil)
        let provider = AssistantFixture(.init(message: "Done", kind: "variation", recipe: recipe, dishes: [], changes: ""))
        provider.delay = 1_000_000_000
        let session = AskCrumbSession(provider: provider)
        session.configure(meal: source, account: AccountStore())
        session.send("Change it.", intent: "variation", meal: source, library: [source], account: AccountStore())
        XCTAssertEqual(session.phase, .recipe)
        session.cancel()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(session.phase)
        XCTAssertEqual(session.turns.count, 1)
        XCTAssertNotNil(session.error)
        session.close()
        UserDefaults.standard.removeObject(forKey: "ask-crumb." + source.id.uuidString)
    }
    func testMealReusesExistingRecipeIDsAndKeepsOtherDishesWhenReplacingSoup() async throws {
        let main = Meal(photo: Data(), name: "Oyakodon", date: .now, place: nil)
        let salad = Meal(photo: Data(), name: "Cabbage salad", date: .now, place: nil)
        let first = AssistantReply(message: "Dinner", kind: "meal", mealTitle: "Oyakodon dinner", dishes: [
            .init(existingRecipeID: main.id.uuidString, title: main.title, portionPerPerson: 1),
            .init(existingRecipeID: salad.id.uuidString, title: salad.title, portionPerPerson: 0.5),
            .init(recipe: recipe, title: recipe.title, portionPerPerson: 1)], changes: "")
        let provider = AssistantFixture(first)
        let session = AskCrumbSession(provider: provider)
        session.configure(meal: main, account: AccountStore())
        session.send("Build dinner.", intent: "meal", meal: main, library: [main,salad], account: AccountStore())
        for _ in 0..<50 where session.phase != nil { try await Task.sleep(for: .milliseconds(10)) }
        let before = try XCTUnwrap(session.turns.last?.proposal)
        var second = first
        var soup = recipe; soup.title = "Miso soup"
        second.dishes[2].recipe = soup; second.dishes[2].title = soup.title
        provider.response = second
        session.send("Replace only the soup.", intent: "meal", meal: main, library: [main,salad], account: AccountStore())
        for _ in 0..<50 where session.phase != nil { try await Task.sleep(for: .milliseconds(10)) }
        let after = try XCTUnwrap(session.turns.last?.proposal)
        XCTAssertEqual(before.components.prefix(2).compactMap(\.recipeID), after.components.prefix(2).compactMap(\.recipeID))
        XCTAssertEqual(after.components.count, 3)
        XCTAssertEqual(after.components.last?.title, "Miso soup")
        XCTAssertNil(after.preview)
        soup.ingredients[0].amount = 450
        second.dishes[2].recipe = soup
        provider.response = second
        session.send("More tofu in the same soup.", intent: "meal", meal: main, library: [main,salad], account: AccountStore())
        for _ in 0..<50 where session.phase != nil { try await Task.sleep(for: .milliseconds(10)) }
        let revised = try XCTUnwrap(session.turns.last?.proposal)
        XCTAssertEqual(revised.components.last?.draft?.recipe.ingredients.first?.amount, 450)
        XCTAssertEqual(revised.components.prefix(2).compactMap(\.recipeID), before.components.prefix(2).compactMap(\.recipeID))
        session.close()
        UserDefaults.standard.removeObject(forKey: "ask-crumb." + main.id.uuidString)
    }
    func testExploreCreatesRecipeWithoutInventingAnOrigin() async throws {
        let session = AskCrumbSession(provider: AssistantFixture(AssistantReply(message: "Try this.", kind: "variation", recipe: recipe)))
        let account = AccountStore()
        session.configure(meal: nil, account: account)
        session.send("Make a tofu bowl.", intent: "variation", meal: nil, library: [], account: account)
        for _ in 0..<50 where session.phase != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(session.error)
        let proposal = try XCTUnwrap(session.turns.last?.proposal)
        XCTAssertNil(proposal.draft.originRecipeID)
        XCTAssertFalse(proposal.draft.recipe.ingredients.isEmpty)
        session.close()
        UserDefaults.standard.removeObject(forKey: "ask-crumb.explore")
    }

}
