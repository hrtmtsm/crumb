import XCTest

final class LocalizationTests: XCTestCase {
    private func strings(_ language: String) throws -> [String: String] {
        let folder = try XCTUnwrap(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let bytes = try Data(contentsOf: folder.appendingPathComponent("Localizable.strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: String])
    }
    func testAllLanguagesCoverTheSameKeysAndFormatArguments() throws {
        let japanese = try strings("ja")
        let argument = try NSRegularExpression(pattern: "%([0-9]+\\$)?(lld|ld|d|@)")
        func placeholders(_ value: String) -> [String] {
            argument.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range(at: 2), in: value)!])
            }.sorted()
        }
        for language in ["en", "ko"] {
            let translated = try strings(language)
            XCTAssertEqual(Set(japanese.keys), Set(translated.keys))
            for (key, value) in japanese {
                XCTAssertFalse(translated[key, default: ""].isEmpty, "Missing \(language): \(key)")
                XCTAssertEqual(placeholders(value), placeholders(translated[key, default: ""]), "Format arguments: \(language) \(key)")
            }
        }
    }
    func testRecentInterfaceCopyIsLocalized() throws {
        for (language, all, menu, title) in [
            ("ja", "すべて", "マイメニュー", "今日は、何が食べたい？"),
            ("ko", "전체", "내 메뉴", "오늘은 뭐가 먹고 싶어요?")
        ] {
            let folder = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: folder))
            XCTAssertEqual(bundle.localizedString(forKey: "All", value: nil, table: nil), all)
            XCTAssertEqual(bundle.localizedString(forKey: "My Menu", value: nil, table: nil), menu)
            XCTAssertEqual(bundle.localizedString(forKey: "今日は、何が食べたい？", value: nil, table: nil), title)
            for key in ["カテゴリ", "ひとこと", "月払い", "深緑の輪花", "プライバシーポリシー"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "MISSING", table: nil), "MISSING")
            }
        }
    }
}
