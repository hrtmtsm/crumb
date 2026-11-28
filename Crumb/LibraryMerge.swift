import Foundation
import CryptoKit

struct SharedPlateAsset: Codable, Equatable {
    var id: UUID
    var path: String
    var x: Double?
    var y: Double?
    var scale: Double?
}
struct CloudRecipe: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var note: String
    var date: Double
    var dateOmitted: Bool?
    var recipe: String
    var structuredRecipe: String?
    var recipeURL: String
    var categories: [String]
    var photoFraming: String?
    var selectedPlateID: String?
    var photoPath: String
    var originalPath: String?
    var plate: SharedPlateAsset?
}
struct BookSnapshot: Codable, Equatable {
    var recipes: [CloudRecipe] = []
    var normalized: Self { Self(recipes: recipes.sorted { $0.id.uuidString < $1.id.uuidString }) }
}
struct RemoteBook: Codable, Identifiable {
    let id: UUID
    let owner_id: UUID
    let client_key: String
    let title: String
    var snapshot: BookSnapshot
    var revision: Int
    let owner_plus: Bool
    func localBook(viewer: UUID) -> MenuBook {
        MenuBook(id: owner_id == viewer ? client_key : id.uuidString.lowercased(), name: owner_id == viewer && client_key == MenuBook.defaultID ? MenuBook.defaultBook.name : title,
                 cloudID: id, ownerID: owner_id, ownerHasPlus: owner_plus, revision: revision)
    }
}

/// Three-way merge: unchanged records follow the remote; concurrent changes retain both copies.
/// Deletions win only when the other side has not modified that record.
enum LibraryMerge {
    static func merge(base: BookSnapshot, local: BookSnapshot, remote: BookSnapshot) -> BookSnapshot {
        let before = Dictionary(base.recipes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let here = Dictionary(local.recipes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let there = Dictionary(remote.recipes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var result = there
        for id in Set(before.keys).union(here.keys).union(there.keys) {
            let old = before[id], ours = here[id], theirs = there[id]
            if ours == old { continue }
            if theirs == old || ours == theirs { result[id] = ours; continue }
            if var ours {
                if theirs == nil {
                    // Remote deletion + local edit: preserve the edit as a new record.
                    ours.id = stableUUID("restore/" + id.uuidString + "/" + digest(ours))
                } else {
                    // Stable conflict IDs make retried writes idempotent, not a new copy on each retry.
                    ours.id = stableUUID("conflict/" + id.uuidString + "/" + digest(ours))
                    ours.name += AppLanguage.text("（別端末の変更）")
                }
                result[ours.id] = ours
            }
            // Local delete + remote edit keeps the remote edit instead of destroying it.
        }
        return BookSnapshot(recipes: Array(result.values)).normalized
    }
    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(value)) ?? Data()
        return hash(data)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func stableUUID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
