import Foundation

/// Only source links cross the share-extension boundary; no recipes or account credentials.
enum RecipeInbox {
    static let group = "group.app.tabinote.meals"
    static func enqueue(_ url: URL) throws {
        guard url.scheme == "https", FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil, let defaults = UserDefaults(suiteName: group) else { throw CocoaError(.fileWriteUnknown) }
        var pending = defaults.stringArray(forKey: "recipeImportURLs") ?? []
        if !pending.contains(url.absoluteString) { pending.append(url.absoluteString) }
        defaults.set(Array(pending.suffix(20)), forKey: "recipeImportURLs")
    }
    static func take() -> String? {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
              let defaults = UserDefaults(suiteName: group), var pending = defaults.stringArray(forKey: "recipeImportURLs"), !pending.isEmpty else { return nil }
        let first = pending.removeFirst()
        defaults.set(pending, forKey: "recipeImportURLs")
        return first
    }
}
