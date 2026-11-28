import XCTest
@testable import crumb

final class LibraryMergeTests: XCTestCase {
    private func record(_ name: String = "Soup") -> CloudRecipe {
        CloudRecipe(id: UUID(), name: name, note: "", date: 1, dateOmitted: nil, recipe: "", structuredRecipe: nil,
                    recipeURL: "", categories: [], photoFraming: nil, selectedPlateID: nil, photoPath: "photo", originalPath: nil)
    }
    func testConcurrentEditsKeepBothAndRetriesAreStable() {
        let original = record(); var local = original; var remote = original
        local.note = "Local"; remote.note = "Remote"
        let base = BookSnapshot(recipes: [original]), ours = BookSnapshot(recipes: [local])
        let merged = LibraryMerge.merge(base: base, local: ours, remote: BookSnapshot(recipes: [remote]))
        XCTAssertEqual(merged.recipes.count, 2)
        XCTAssertEqual(Set(merged.recipes.map(\.note)), ["Local", "Remote"])
        XCTAssertEqual(LibraryMerge.merge(base: base, local: ours, remote: merged), merged)
    }
    func testDeletionDoesNotDestroyConcurrentEdit() {
        let original = record(); var edited = original; edited.note = "Keep me"
        let base = BookSnapshot(recipes: [original]), changed = BookSnapshot(recipes: [edited]), empty = BookSnapshot()
        XCTAssertEqual(LibraryMerge.merge(base: base, local: empty, remote: changed), changed)
        let restored = LibraryMerge.merge(base: base, local: changed, remote: empty)
        XCTAssertEqual(restored.recipes.count, 1)
        XCTAssertEqual(restored.recipes.first?.note, "Keep me")
        XCTAssertNotEqual(restored.recipes.first?.id, original.id)
        XCTAssertEqual(LibraryMerge.merge(base: base, local: empty, remote: base), empty)
    }
    func testNewDevicePullsAllRemoteRecipes() {
        let remote = BookSnapshot(recipes: [record(), record("Pasta")]).normalized
        XCTAssertEqual(LibraryMerge.merge(base: .init(), local: .init(), remote: remote), remote)
    }
}
