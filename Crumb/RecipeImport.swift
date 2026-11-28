import Foundation

// Import only explicit recipe data; never infer missing quantities or cooking steps.
enum RecipeImport {
    enum ImportError: Error { case invalidURL, unavailable, noRecipe, tooLarge }

    static func ingredient(_ raw: String) -> RecipeIngredient {
        let text = clean(raw).trimmingCharacters(in: CharacterSet(charactersIn: "•・- \t"))
        let number = #"(?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:[.,]\d+)?|[½¼¾])"#
        let units = #"(?:tablespoons?|teaspoons?|tbsp|tsp|cups?|grams?|kilograms?|kg|mg|ml|mL|g|l|L|個|本|枚|片|玉|袋|缶|丁|合)"#
        func amount(_ value: String) -> Double? {
            let fractions: [String: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75]
            if let value = fractions[value] { return value }
            let parts = value.split(separator: " ")
            if parts.count == 2, let whole = Double(parts[0]), let fraction = amount(String(parts[1])) { return whole + fraction }
            let ratio = value.split(separator: "/")
            if ratio.count == 2, let n = Double(ratio[0]), let d = Double(ratio[1]), d > 0 { return n / d }
            return Double(value.replacingOccurrences(of: ",", with: "."))
        }
        let patterns = ["^(\(number))\\s*(\(units))?\\s+(.+)$", "^(.+?)\\s+(\(number))\\s*(\(units))?$"]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func group(_ n: Int) -> String { Range(match.range(at: n), in: text).map { String(text[$0]) } ?? "" }
            let name = group(index == 0 ? 3 : 1)
            let value = amount(group(index == 0 ? 1 : 2))
            if let value, value.isFinite, value > 0 {
                return RecipeIngredient(name: name, amount: value, unit: group(index == 0 ? 2 : 3))
            }
        }
        return RecipeIngredient(name: text, unit: "")
    }

    static func fromText(_ text: String, ingredients: Bool) -> MealRecipe {
        let lines = text.components(separatedBy: .newlines).map(clean).filter { !$0.isEmpty }
        var recipe = MealRecipe()
        if ingredients { recipe.ingredients = lines.map(ingredient) }
        else { recipe.steps = lines }
        return recipe
    }

    static func fromHTML(_ html: String) throws -> MealRecipe {
        let pattern = #"<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script\s*>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let data = String(html[range]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let object = findRecipe(json) else { continue }
            var result = MealRecipe()
            result.servingsKnown = false
            result.ingredients = strings(object["recipeIngredient"]).map(ingredient).filter { !$0.name.isEmpty }
            result.steps = instructions(object["recipeInstructions"])
            // recipeYield can mean cookies or pancakes, not people. Only use explicit servings.
            if let yield = object["recipeYield"] {
                let values = strings(yield)
                let explicit = values.first { value in
                    value.range(of: #"(?i)serv(?:es|ings?)?|people|persons?|人前|人分|인분"#, options: .regularExpression) != nil
                }
                if let value = explicit, let regex = try? NSRegularExpression(pattern: #"\d+"#),
                   let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                   let range = Range(match.range, in: value), let servings = Int(value[range]) {
                    result.servings = min(99, max(1, servings))
                    result.servingsKnown = true
                }
            }
            if !result.isEmpty { return result }
        }
        throw ImportError.noRecipe
    }

    private static func metadataRecipe(_ html: String) -> [String: Any]? {
        let pattern = #"<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>([\s\S]*?)</script\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            if let range = Range(match.range(at: 1), in: html), let bytes = String(html[range]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: bytes), let recipe = findRecipe(json) { return recipe }
        }
        return nil
    }
    private static func findRecipe(_ value: Any) -> [String: Any]? {
        if let list = value as? [Any] { return list.lazy.compactMap(findRecipe).first }
        guard let object = value as? [String: Any] else { return nil }
        if strings(object["@type"]).contains(where: { $0 == "Recipe" || $0.hasSuffix("/Recipe") }) { return object }
        return object.values.lazy.compactMap(findRecipe).first
    }
    private static func strings(_ value: Any?) -> [String] {
        if let text = value as? String { return [clean(text)].filter { !$0.isEmpty } }
        if let value = value as? NSNumber { return [value.stringValue] }
        if let list = value as? [Any] { return list.flatMap { strings($0) } }
        if let object = value as? [String: Any] {
            if let text = object["text"] ?? object["name"] { return strings(text) }
            if let list = object["itemListElement"] { return strings(list) }
        }
        return []
    }
    private static func instructions(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.flatMap { instructions($0) } }
        if let object = value as? [String: Any], let list = object["itemListElement"] { return instructions(list) }
        return strings(value).flatMap { $0.components(separatedBy: .newlines) }.map(clean).filter { !$0.isEmpty }
    }
    private static func clean(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"<(?:br\s*/?|/p)>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">")] {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(), host.contains("."),
              host.rangeOfCharacter(from: .letters) != nil,
              !host.contains(":"), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.hasSuffix(".internal") else { return false }
        return true
    }

    static func fetch(_ raw: String) async throws -> MealRecipe { try await fetchDraft(raw).recipe }

    static func fetchDraft(_ raw: String) async throws -> RecipeDraft {
        let html = try await fetchHTML(raw)
        do {
            var recipe = try fromHTML(html)
            let metadata = metadataRecipe(html)
            let recipeName = (metadata?["name"] as? String).map(clean)
            let notes = (metadata?["description"] as? String).map(clean) ?? ""
            let titlePattern = #"<title[^>]*>([\s\S]*?)</title>"#
            let regex = try NSRegularExpression(pattern: titlePattern, options: [.caseInsensitive])
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
            let title = match.flatMap { Range($0.range(at: 1), in: html) }.map { clean(String(html[$0])) } ?? ""
            return RecipeDraft(title: recipeName ?? title, recipe: recipe, notes: notes, source: raw)
        } catch {
            let pattern = #""shortDescription"\s*:\s*("(?:\\.|[^"\\])*")"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html),
               let data = String(html[range]).data(using: .utf8),
               let description = try? JSONDecoder().decode(String.self, from: data) {
                var draft = transcript(description)
                draft.source = raw
                return draft
            }
            var recipe = MealRecipe(); recipe.servingsKnown = false
            return RecipeDraft(title: "", recipe: recipe, source: raw)
        }
    }

    static func transcript(_ text: String) -> RecipeDraft {
        var recipe = MealRecipe(); recipe.servingsKnown = false
        var section = "", title = "", notes: [String] = []
        for line in text.components(separatedBy: .newlines).map(clean).filter({ !$0.isEmpty }) {
            let normalized = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
            if ["ingredients", "materials", "材料"].contains(normalized) { section = "ingredients"; continue }
            if ["directions", "instructions", "steps", "method", "手順", "作り方"].contains(normalized) { section = "steps"; continue }
            if ["notes", "note", "メモ"].contains(normalized) { section = "notes"; continue }
            if normalized.hasPrefix("title:") || normalized.hasPrefix("dish:") { title = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces); continue }
            if normalized.hasPrefix("serves "), let count = Int(normalized.dropFirst(7)), (1...99).contains(count) {
                recipe.servings = count; recipe.servingsKnown = true; continue
            }
            switch section {
            case "ingredients": recipe.ingredients.append(ingredient(line))
            case "steps": recipe.steps.append(line)
            default: notes.append(line)
            }
        }
        return RecipeDraft(title: title, recipe: recipe, notes: notes.joined(separator: "\n"))
    }

    private static func fetchHTML(_ raw: String) async throws -> String {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), allowed(url) else { throw ImportError.invalidURL }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = response.url, allowed(finalURL) else { throw ImportError.unavailable }
        guard response.expectedContentLength <= 4_000_000 else { throw ImportError.tooLarge }
        var data = Data()
        for try await byte in stream {
            if data.count >= 4_000_000 { throw ImportError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .japaneseEUC) else { throw ImportError.noRecipe }
        return html
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.map(RecipeImport.allowed) == true ? request : nil)
        }
    }
}
