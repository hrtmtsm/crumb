import Foundation

struct InstagramDraft: Codable, Identifiable {
    let id: UUID
    let url: URL?
    let text: String
    var confirmation: Confirmation?

    struct Confirmation: Codable {
        let name: String
        let address: String
        let latitude: Double
        let longitude: Double
        let mapID: String
    }

    struct Destination: Codable, Identifiable {
        let id: String
        let title: String
    }

    private static var settings: UserDefaults? {
        UserDefaults(suiteName: "group.app.tabinote.meals")
    }

    static var destinations: [Destination] {
        guard let data = settings?.data(forKey: "destinations"),
              let maps = try? JSONDecoder().decode([Destination].self, from: data) else {
            return [Destination(id: "mine", title: "行きたいお店")]
        }
        return maps
    }

    static var lastMap: String { settings?.string(forKey: "lastMap") ?? "mine" }

    static func updateDestinations(_ maps: [Destination], lastMap: String) {
        settings?.set(try? JSONEncoder().encode(maps), forKey: "destinations")
        settings?.set(lastMap, forKey: "lastMap")
    }

    init(items: [String]) {
        id = UUID()
        let combined = items.joined(separator: "\n")
        let detectedURL = (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue))?
            .matches(in: combined, range: NSRange(combined.startIndex..., in: combined))
            .compactMap(\.url).first {
                $0.scheme == "https" && ["instagram.com", "www.instagram.com"].contains($0.host?.lowercased() ?? "")
            }
        url = detectedURL
        text = items.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != detectedURL?.absoluteString }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.tabinote.meals")?.appendingPathComponent("InstagramInbox", isDirectory: true)
    }

    func enqueue() throws {
        guard let directory = Self.directory else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(id.uuidString), options: .atomic)
    }

    static func pending() -> [Self] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }
        return files.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
    }

    func remove() {
        guard let directory = Self.directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString))
    }
}

private extension URL {
    var creationDate: Date? { try? resourceValues(forKeys: [.creationDateKey]).creationDate }
}
