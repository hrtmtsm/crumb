import SwiftUI
import SwiftData

private struct CategoryActions: ViewModifier {
    let category: String?
    let enabled: Bool
    let canEdit: (String) -> Bool
    let changed: (String, String?) -> Void
    @Query private var meals: [Meal]
    @Environment(\.modelContext) private var context
    @AppStorage("recipeCategories") private var storedCategories = "[]"
    @State private var renaming = false
    @State private var deleting = false
    @State private var name = ""
    @State private var error: String?

    private var affected: [Meal] {
        guard let category else { return [] }
        return meals.filter { $0.wantToVisit != true && $0.categories.contains { RecipeCategories.matches($0, category) } }
    }
    private var permitted: Bool {
        enabled && affected.allSatisfy { canEdit($0.menuBookID ?? MenuBook.defaultID) }
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if category != nil {
                    Button("名前を変更", systemImage: "pencil") { CrumbHaptics.tap();
                        name = category ?? ""
                        renaming = true
                    }.disabled(!permitted)
                    Button("カテゴリを削除", systemImage: "trash", role: .destructive) { CrumbHaptics.tap();
                        deleting = true
                    }.disabled(!permitted)
                }
            }
            .alert("カテゴリ名を変更", isPresented: $renaming) {
                TextField("カテゴリ名", text: $name)
                Button("保存") { CrumbHaptics.tap(); apply(name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("キャンセル", role: .cancel) { CrumbHaptics.tap() }
            }
            .confirmationDialog("カテゴリを削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
                Button("カテゴリを削除", role: .destructive) { CrumbHaptics.tap(); apply(nil) }
                Button("キャンセル", role: .cancel) { CrumbHaptics.tap() }
            } message: {
                Text("レシピは削除されません。このカテゴリのレシピは「すべて」から見られます。")
            }
            .alert("操作を完了できませんでした", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("閉じる", role: .cancel) { CrumbHaptics.tap() }
            } message: { Text(error ?? "") }
    }

    private func apply(_ proposed: String?) {
        guard let category, permitted else { return }
        let replacement = proposed?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let replacement, replacement.isEmpty { return }
        let names = RecipeCategories.decode(storedCategories) + meals.flatMap(\.categories)
        if let replacement, names.contains(where: { !RecipeCategories.matches($0, category) && RecipeCategories.matches($0, replacement) }) {
            error = AppLanguage.text("同じ名前のカテゴリがあります。別の名前を入力してください。")
            return
        }
        for meal in affected {
            meal.categories = RecipeCategories.replacing(category, with: replacement, in: meal.categories)
        }
        do {
            try context.save()
            storedCategories = RecipeCategories.encode(RecipeCategories.replacing(category, with: replacement,
                in: RecipeCategories.normalized(RecipeCategories.decode(storedCategories) + [category])))
            changed(category, replacement)
            CrumbHaptics.success()
            NotificationCenter.default.post(name: .crumbLibraryChanged, object: nil)
        } catch {
            context.rollback()
            self.error = AppLanguage.text("カテゴリを変更できませんでした。もう一度お試しください。")
        }
    }
}

extension View {
    func categoryActions(_ category: String?, enabled: Bool, canEdit: @escaping (String) -> Bool,
                         changed: @escaping (String, String?) -> Void) -> some View {
        modifier(CategoryActions(category: category, enabled: enabled, canEdit: canEdit, changed: changed))
    }
}
