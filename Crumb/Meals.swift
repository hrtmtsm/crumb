import SwiftUI
import SwiftData
import MapKit
import ImageIO

@Model
final class Meal {
    var id = UUID()
    @Attribute(.externalStorage) var photo: Data
    @Attribute(.externalStorage) var originalPhoto: Data?
    var selectedPlateID: String?
    var photoFraming: String?
    var name: String
    var date: Date
    var dateOmitted: Bool?
    var recordedDate: Date? { dateOmitted == true ? nil : date }
    var wantToVisit: Bool?
    var sourceURL: String?
    var additionalSourceURLs: String?
    var addedBy: String?
    var visited: Bool?

    var instagramLinks: [URL] {
        ([sourceURL].compactMap { $0 } + (additionalSourceURLs ?? "").split(separator: "\n").map(String.init))
            .compactMap(URL.init(string:))
    }

    func appendInstagramLink(_ url: URL) {
        guard !instagramLinks.contains(url) else { return }
        if sourceURL == nil { sourceURL = url.absoluteString }
        else { additionalSourceURLs = [additionalSourceURLs, url.absoluteString].compactMap { $0 }.joined(separator: "\n") }
    }
    var note = ""
    var recipe = ""
    var structuredRecipe: String?
    var categoryData: String?
    var menuBookID: String?
    var recipeURL = ""
    var recipeUpdatedAt: Date?
    var placeName: String?
    var placeAddress: String?
    var placeKey: String?
    var placeIsVenue: Bool?
    var latitude: Double?
    var longitude: Double?

    init(photo: Data, name: String, date: Date, place: Place?) {
        self.photo = photo
        self.name = name
        self.date = date
        setPlace(place)
    }

    var categories: [String] {
        get {
            guard let categoryData, let data = categoryData.data(using: .utf8),
                  let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Array(RecipeCategories.normalized(names).prefix(1))
        }
        set {
            let names = Array(RecipeCategories.normalized(newValue).prefix(1))
            categoryData = names.isEmpty ? nil : (try? JSONEncoder().encode(names)).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    var title: String { name.isEmpty ? AppLanguage.text("名前のない料理") : name }
    var place: Place? {
        guard let placeName, let placeKey else { return nil }
        if placeKey == Place.home.id { return .home }
        return Place(id: placeKey, name: placeName, address: placeAddress ?? "",
                     latitude: latitude, longitude: longitude,
                     isVenue: placeIsVenue == true || placeKey.hasPrefix("sample-"))
    }

    func setPlace(_ place: Place?) {
        placeName = place?.name
        placeAddress = place?.address
        placeKey = place?.id
        placeIsVenue = place?.isVenue
        latitude = place?.latitude
        longitude = place?.longitude
    }
}

struct Place: Identifiable {
    var id: String
    var name: String
    var address: String
    var latitude: Double?
    var longitude: Double?
    var isVenue: Bool

    static let home = Place(id: "home", name: "おうち", address: "")
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }

    init(id: String, name: String, address: String, latitude: Double? = nil, longitude: Double? = nil, isVenue: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.isVenue = isVenue
    }

    init(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        let name = item.name ?? "名称未設定"
        let key = "\(name)|\(Int((coordinate.latitude * 10000).rounded()))|\(Int((coordinate.longitude * 10000).rounded()))"
        self.init(id: key, name: name, address: item.placemark.title ?? "",
                  latitude: coordinate.latitude, longitude: coordinate.longitude,
                  isVenue: item.pointOfInterestCategory != nil)
    }
}

let paper = Color.white
let ink = Color(red: 38/255, green: 34/255, blue: 31/255)
let secondaryInk = Color(red: 110/255, green: 101/255, blue: 93/255)
let placeholderInk = Color(red: 116/255, green: 108/255, blue: 100/255)
let fieldBorder = Color(red: 228/255, green: 223/255, blue: 218/255)
let clay = ink
let tomato = Color(red: 235/255, green: 96/255, blue: 74/255)

func dayLabel(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().year().locale(AppLanguage.locale))
}

extension Data {
    var isPlatedPhoto: Bool {
        // PhotoPlating exports transparent PNGs; ordinary imports are encoded as JPEG.
        starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    }
}

struct MealPhoto: View {
    let data: Data
    let size: Int
    var contentMode: ContentMode = .fill

    var body: some View {
        GeometryReader { geometry in
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let photo = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size
               ] as CFDictionary) {
                Image(uiImage: UIImage(cgImage: photo))
                    .resizable().aspectRatio(contentMode: contentMode)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                Color.white.overlay { Image(systemName: "fork.knife").foregroundStyle(clay) }
            }
        }
        .accessibilityHidden(true)
    }
}

enum Samples {
    static let shop = Place(id: "sample-sapporo-curry", name: "スープカレー ひだまり",
                            address: "北海道札幌市中央区", latitude: 43.0586, longitude: 141.3514)
    static let cafe = Place(id: "sample-sapporo-cafe", name: "喫茶こはく",
                            address: "北海道札幌市中央区", latitude: 43.0675, longitude: 141.3432)

    static func insert(into context: ModelContext) throws {
        let examples = [
            ("carbonara", "カルボナーラ", 14, Place.home, "黒こしょうをたっぷり。", "パスタ100g、卵1個、粉チーズ25g、ベーコン40g。\nゆでたパスタと炒めたベーコンを合わせ、火を止めて卵とチーズを混ぜる。"),
            ("curry", "チキンのスープカレー", 11, shop, "札幌に着いて最初の一皿。", ""),
            ("pudding", "喫茶店のプリン", 10, cafe, "窓際の席でひと休み。", ""),
            ("vegetables", "焼き野菜のスープカレー", 9, shop, "帰る前にもう一度。", "")
        ]
        for (asset, title, day, place, note, recipe) in examples {
            guard let url = Bundle.main.url(forResource: asset, withExtension: "jpg") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let date = Calendar.current.date(from: .init(year: 2026, month: 10, day: day, hour: 12)) ?? .now
            let meal = Meal(photo: try Data(contentsOf: url), name: title, date: date, place: place)
            meal.note = note
            meal.recipe = recipe
            context.insert(meal)
        }
        try context.save()
    }
}

func crumbFont(_ size: CGFloat) -> Font {
    .custom("BricolageGrotesque-48ptBold", size: size, relativeTo: .largeTitle)
}

enum RecipeCategories {
    static func decode(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8), let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalized(names)
    }
    static func encode(_ names: [String]) -> String {
        guard let data = try? JSONEncoder().encode(normalized(names)) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
    static func normalized(_ names: [String]) -> [String] {
        var keys = Set<String>()
        return names.compactMap { name in
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, keys.insert(clean.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted else { return nil }
            return clean
        }
    }
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

struct MenuBook: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    static let defaultID = "default"
    static let defaultBook = MenuBook(id: defaultID, name: "My Menu")
    static func decode(_ value: String) -> [MenuBook] {
        let saved = value.data(using: .utf8).flatMap { try? JSONDecoder().decode([MenuBook].self, from: $0) } ?? []
        var ids: Set<String> = [defaultID]
        return [defaultBook] + saved.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ids.insert($0.id).inserted }
    }
    static func encode(_ books: [MenuBook]) -> String {
        guard let data = try? JSONEncoder().encode(books.filter { $0.id != defaultID }) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
