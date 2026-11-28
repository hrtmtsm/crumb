import SwiftUI
import SwiftData
import CryptoKit

@MainActor
final class CloudLibrary: ObservableObject {
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var remoteBooks: [String: MenuBook] = [:]
    @Published var error: String?
    @Published var notice: String?
    private var account: AccountStore?
    private var context: ModelContext?
    private var defaults: UserDefaults = .standard
    private var userID: UUID?
    private var again = false
    private var baselines: [String: BookSnapshot] = [:]
    private var stateBaseline: CloudAccountState?
    private var cacheURL: URL?

    func configure(account: AccountStore, context: ModelContext, defaults: UserDefaults) {
        self.account = account; self.context = context; self.defaults = defaults
        userID = account.session?.userID
        if let userID {
            let root = URL.applicationSupportDirectory.appendingPathComponent("Accounts")
            cacheURL = root.appendingPathComponent(userID.uuidString.lowercased() + ".sync.json")
            if let data = try? Data(contentsOf: cacheURL!), let value = try? JSONDecoder().decode(Checkpoint.self, from: data) {
                baselines = value.books; stateBaseline = value.state
            }
        }
    }
    func resolved(_ book: MenuBook) -> MenuBook { remoteBooks[book.id] ?? book }
    static var enabled: Bool { Bundle.main.object(forInfoDictionaryKey: "CrumbCloudEnabled") as? String == "YES" }
    var available: Bool { userID != nil && Self.enabled }
    private var api: SupabaseREST? {
        guard Self.enabled, let account, let userID else { return nil }
        return SupabaseREST(account: account, userID: userID)
    }

    func sync() async {
        guard let api, let context, let userID else { return }
        if syncing { again = true; return }
        syncing = true; defer { syncing = false }
        do {
            // One bounded retry merges a concurrent writer instead of overwriting it.
            for attempt in 0..<2 {
                do {
                    try await syncLibrary(api: api, context: context, userID: userID)
                    try await syncAccountState(api: api, context: context, userID: userID)
                    guard account?.session?.userID == userID else { throw CancellationError() }
                    lastSync = .now; error = nil
                    break
                } catch let failure as CloudError where failure.status == 409 && attempt == 0 {
                    continue
                }
            }
        } catch is CancellationError { return }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? AppLanguage.text("同期できませんでした。端末の記録は保持しています。") }
        if again { again = false; Task { [weak self] in await self?.sync() } }
    }

    func createBook(_ name: String) async throws -> MenuBook {
        guard let api, let userID else { throw AccountError.expired }
        struct Input: Encodable { let p_client_key: String; let p_title: String }
        let remote = try await api.rpc("crumb_create_book", Input(p_client_key: UUID().uuidString.lowercased(), p_title: name), as: RemoteBook.self)
        let book = remote.localBook(viewer: userID)
        var books = MenuBook.decode(defaults.string(forKey: "menuBooks") ?? "[]")
        books.append(book); defaults.set(MenuBook.encode(books), forKey: "menuBooks")
        remoteBooks[book.id] = book
        return book
    }
    func invite(to book: MenuBook) async throws -> String {
        await sync()
        guard let api, let id = resolved(book).cloudID else { throw CloudError(status: 0) }
        struct Input: Encodable { let p_book: UUID }
        return try await api.rpc("crumb_create_invite", Input(p_book: id), as: String.self)
    }
    func join(_ raw: String) async throws -> UUID {
        let token = InviteRouter.token(from: raw)
        guard let api, let token else { throw CloudError(status: 404) }
        struct Input: Encodable { let p_token: String }
        let id = try await api.rpc("crumb_accept_invite", Input(p_token: token), as: UUID.self)
        await sync()
        defaults.set(id.uuidString.lowercased(), forKey: "selectedMenuBook")
        return id
    }
    func revokeInvites(_ book: MenuBook) async throws {
        guard let api, let id = resolved(book).cloudID else { throw CloudError(status: 404) }
        struct Input: Encodable { let p_book: UUID }
        _ = try await api.rpc("crumb_revoke_invites", Input(p_book: id), as: EmptyResponse.self)
    }
    func leave(_ book: MenuBook) async throws {
        guard let api, let id = resolved(book).cloudID, let userID else { throw CloudError(status: 404) }
        struct Input: Encodable { let p_book: UUID; let p_member: UUID }
        _ = try await api.rpc("crumb_remove_member", Input(p_book: id, p_member: userID), as: EmptyResponse.self)
        await sync()
        defaults.set(MenuBook.defaultID, forKey: "selectedMenuBook")
    }

    private func syncLibrary(api: SupabaseREST, context: ModelContext, userID: UUID) async throws {
        var localBooks = MenuBook.decode(defaults.string(forKey: "menuBooks") ?? "[]")
        struct Create: Encodable { let p_client_key: String; let p_title: String }
        var remotes = try await api.rpc("crumb_list_books", as: [RemoteBook].self)
        // A free account can initialize its private default book; cloud writes still require Plus.
        if !remotes.contains(where: { $0.owner_id == userID && $0.client_key == MenuBook.defaultID }) {
            let value = try await api.rpc("crumb_create_book", Create(p_client_key: MenuBook.defaultID, p_title: "My Menu"), as: RemoteBook.self)
            remotes.append(value)
        }
        // Preserve pre-existing local-only books. They are uploaded only with a server-confirmed Plus entitlement.
        struct Plan: Decodable { let active: Bool }
        let plan = try await api.rpc("crumb_my_plan", as: Plan.self)
        if plan.active {
            for book in localBooks where PlanPolicy.isOwned(book, viewer: userID) && !remotes.contains(where: { $0.owner_id == userID && $0.client_key == book.id }) {
                remotes.append(try await api.rpc("crumb_create_book", Create(p_client_key: book.id, p_title: book.name), as: RemoteBook.self))
            }
        }
        let homePlates = try context.fetch(FetchDescriptor<HomePlate>())
        let initial = try context.fetch(FetchDescriptor<Meal>()).filter { $0.wantToVisit != true }
        var original: [String: BookSnapshot] = [:]
        var merged: [UUID: BookSnapshot] = [:]
        let previousBaselines = baselines
        let previousBooks = remoteBooks
        struct Write: Encodable { let id: UUID; let revision: Int; let snapshot: BookSnapshot }
        var writes: [Write] = []
        for remote in remotes {
            let book = remote.localBook(viewer: userID)
            let local = snapshot(meals: initial.filter { ($0.menuBookID ?? MenuBook.defaultID) == book.id }, cloudBook: remote.id)
            original[book.id] = local
            let base = baselines[remote.id.uuidString] ?? BookSnapshot()
            let combined = LibraryMerge.merge(base: base, local: local, remote: remote.snapshot)
            // An expired owner keeps reads. Pending local edits are retained locally, not silently published or discarded.
            if remote.owner_plus {
                merged[remote.id] = combined
                if combined != remote.snapshot.normalized {
                    for record in combined.recipes {
                        if let asset = record.plate, let plate = homePlates.first(where: { $0.identifier == asset.id }) {
                            try await upload(plate.photo, path: asset.path, api: api)
                        }
                        if let meal = initial.first(where: { $0.id == record.id }) {
                            try await upload(meal.photo, path: record.photoPath, api: api)
                            if let path = record.originalPath, let data = meal.originalPhoto { try await upload(data, path: path, api: api) }
                        } else if let source = local.recipes.first(where: { $0.photoPath == record.photoPath }),
                                  let meal = initial.first(where: { $0.id == source.id }) {
                            try await upload(meal.photo, path: record.photoPath, api: api)
                            if let path = record.originalPath, let data = meal.originalPhoto { try await upload(data, path: path, api: api) }
                        }
                    }
                    writes.append(Write(id: remote.id, revision: remote.revision, snapshot: combined))
                }
            } else {
                // Merge reads with unsynced local edits, but don't advance their baseline until uploaded.
                merged[remote.id] = combined
            }
        }
        // Download every needed image before changing SwiftData. A failed download leaves the local library intact.
        var files: [String: Data] = [:]
        for remote in remotes {
            for record in merged[remote.id]?.recipes ?? [] {
                for path in [record.photoPath, record.originalPath, record.plate?.path].compactMap({ $0 }) where files[path] == nil {
                    if let local = initial.first(where: { imagePath($0.photo, cloudBook: remote.id) == path }) { files[path] = local.photo }
                    else if let local = initial.first(where: { $0.originalPhoto.map { imagePath($0, cloudBook: remote.id) == path } == true }) { files[path] = local.originalPhoto }
                    else if let plate = homePlates.first(where: { imagePath($0.photo, cloudBook: remote.id) == path }) { files[path] = plate.photo }
                    else { files[path] = try await download(path, api: api) }
                }
            }
        }
        if !writes.isEmpty {
            struct Input: Encodable { let p_books: [Write] }
            _ = try await api.rpc("crumb_save_library", Input(p_books: writes), as: [String: Int].self)
        }
        // If an editor saved while networking was in flight, retry from the old baseline instead of overwriting the new edit.
        let now = try context.fetch(FetchDescriptor<Meal>()).filter { $0.wantToVisit != true }
        for remote in remotes {
            let book = remote.localBook(viewer: userID)
            if snapshot(meals: now.filter { ($0.menuBookID ?? MenuBook.defaultID) == book.id }, cloudBook: remote.id) != original[book.id] {
                again = true; return
            }
        }
        guard account?.session?.userID == userID else { throw CancellationError() }
        for remote in remotes {
            let book = remote.localBook(viewer: userID)
            guard let value = merged[remote.id] else { continue }
            let existing = now.filter { ($0.menuBookID ?? MenuBook.defaultID) == book.id }
            let ids = Set(value.recipes.map(\.id))
            for meal in existing where !ids.contains(meal.id) { context.delete(meal) }
            for record in value.recipes {
                guard let photo = files[record.photoPath] else { throw CloudError(status: 0) }
                let meal = existing.first { $0.id == record.id } ?? Meal(photo: photo, name: record.name, date: Date(timeIntervalSince1970: record.date), place: nil)
                if !existing.contains(where: { $0.id == record.id }) { meal.id = record.id; context.insert(meal) }
                meal.name = record.name; meal.note = record.note; meal.date = Date(timeIntervalSince1970: record.date)
                meal.dateOmitted = record.dateOmitted; meal.recipe = record.recipe; meal.structuredRecipe = record.structuredRecipe
                meal.recipeURL = record.recipeURL; meal.categories = record.categories; meal.photo = photo
                meal.originalPhoto = record.originalPath.flatMap { files[$0] }; meal.photoFraming = record.photoFraming
                if let asset = record.plate, !homePlates.contains(where: { $0.identifier == asset.id }),
                   let data = files[asset.path], !(try context.fetch(FetchDescriptor<HomePlate>())).contains(where: { $0.identifier == asset.id }) {
                    let plate = HomePlate(photo: data); plate.identifier = asset.id
                    plate.foodX = asset.x; plate.foodY = asset.y; plate.foodScale = asset.scale
                    context.insert(plate)
                }
                meal.selectedPlateID = record.selectedPlateID; meal.menuBookID = book.id == MenuBook.defaultID ? nil : book.id
            }
            // Read-only pulls must not mark pending local edits as successfully uploaded.
            baselines[remote.id.uuidString] = remote.owner_plus ? value : remote.snapshot.normalized
            remoteBooks[book.id] = book
            if book.id != MenuBook.defaultID {
                localBooks.removeAll { $0.id == book.id }; localBooks.append(book)
            }
            if value.recipes.contains(where: { $0.name.hasSuffix(AppLanguage.text("（別端末の変更）")) }) {
                notice = AppLanguage.text("別端末の変更を検出したため、両方のコピーを残しました。")
            }
        }
        // Membership revoked online: remove that shared cache; never touch owned/guest notebooks.
        let accessible = Set(remotes.map { $0.id })
        let revoked = localBooks.filter { $0.ownerID != nil && $0.ownerID != userID && $0.cloudID.map { !accessible.contains($0) } == true }
        for book in revoked {
            for meal in now where meal.menuBookID == book.id { context.delete(meal) }
            localBooks.removeAll { $0.id == book.id }; remoteBooks.removeValue(forKey: book.id)
        }
        do { try context.save() } catch { context.rollback(); baselines = previousBaselines; remoteBooks = previousBooks; throw error }
        defaults.set(MenuBook.encode(localBooks), forKey: "menuBooks")
        try checkpoint()

    }

    private func snapshot(meals: [Meal], cloudBook: UUID) -> BookSnapshot {
        let plates = (try? context?.fetch(FetchDescriptor<HomePlate>())) ?? []
        return BookSnapshot(recipes: meals.map { meal in
            let plate = plates.first { $0.identifier?.uuidString == meal.selectedPlateID }
            let asset = plate.flatMap { value -> SharedPlateAsset? in
                guard let id = value.identifier else { return nil }
                return SharedPlateAsset(id: id, path: imagePath(value.photo, cloudBook: cloudBook), x: value.foodX, y: value.foodY, scale: value.foodScale)
            }
            return CloudRecipe(id: meal.id, name: meal.name, note: meal.note, date: meal.date.timeIntervalSince1970,
                        dateOmitted: meal.dateOmitted, recipe: meal.recipe, structuredRecipe: meal.structuredRecipe,
                        recipeURL: meal.recipeURL, categories: meal.categories, photoFraming: meal.photoFraming,
                        selectedPlateID: meal.selectedPlateID, photoPath: imagePath(meal.photo, cloudBook: cloudBook),
                        originalPath: meal.originalPhoto.map { imagePath($0, cloudBook: cloudBook) }, plate: asset)
        }).normalized
    }
    private func imagePath(_ data: Data, cloudBook: UUID) -> String {
        "b/" + cloudBook.uuidString.lowercased() + "/" + LibraryMerge.hash(data) + (data.isPlatedPhoto ? ".png" : ".jpg")
    }
    private func upload(_ data: Data, path: String, api: SupabaseREST) async throws {
        guard data.count <= 20 * 1024 * 1024 else { throw CloudError(status: 413) }
        do {
            _ = try await api.request("storage/v1/object/crumb-photos/" + path, method: "POST", data: data,
                                      mime: data.isPlatedPhoto ? "image/png" : "image/jpeg", extra: ["x-upsert": "false"])
        } catch let failure as CloudError where failure.status == 409 || failure.status == 400 {
            // Storage returns 400 for an existing immutable object. Only accept it when the bytes match.
            guard try await download(path, api: api) == data else { throw failure }
        }
    }
    private func download(_ path: String, api: SupabaseREST) async throws -> Data {
        guard !path.contains(".."), path.range(of: "^[bu]/[0-9a-fA-F-]{36}/[0-9a-f]{64}\\.(png|jpg)$", options: .regularExpression) != nil else { throw CloudError(status: 0) }
        return try await api.request("storage/v1/object/authenticated/crumb-photos/" + path)
    }

    private struct CloudPlate: Codable, Equatable { let id: UUID; let path: String; let date: Double; let x: Double?; let y: Double?; let scale: Double? }
    private struct CloudAccountState: Codable, Equatable { var name: String; var avatar: Data; var categories: String; var plates: [CloudPlate] }
    private struct StateResponse: Decodable { let payload: CloudAccountState; let revision: Int }
    private func syncAccountState(api: SupabaseREST, context: ModelContext, userID: UUID) async throws {
        let remote = try await api.rpc("crumb_get_account_state", as: StateResponse?.self)
        let plates = try context.fetch(FetchDescriptor<HomePlate>())
        for plate in plates where plate.identifier == nil { plate.identifier = LibraryMerge.stableUUID(LibraryMerge.hash(plate.photo)) }
        var local = CloudAccountState(name: defaults.string(forKey: "profileName") ?? "", avatar: defaults.data(forKey: "profileAvatar") ?? Data(),
                                      categories: defaults.string(forKey: "recipeCategories") ?? "[]", plates: plates.compactMap {
            guard let id = $0.identifier else { return nil }
            return CloudPlate(id: id, path: "u/" + userID.uuidString.lowercased() + "/" + LibraryMerge.hash($0.photo) + ($0.photo.isPlatedPhoto ? ".png" : ".jpg"), date: $0.addedAt.timeIntervalSince1970, x: $0.foodX, y: $0.foodY, scale: $0.foodScale)
        }.sorted { $0.id.uuidString < $1.id.uuidString })
        let originalState = local
        if let remote {
            if local == stateBaseline { local = remote.payload }
            else {
                let their = remote.payload
                if local.name.isEmpty || local.name == stateBaseline?.name { local.name = their.name }
                if local.avatar.isEmpty || local.avatar == stateBaseline?.avatar { local.avatar = their.avatar }
                local.categories = RecipeCategories.encode(RecipeCategories.decode(local.categories) + RecipeCategories.decode(their.categories))
                for plate in their.plates where !local.plates.contains(where: { $0.id == plate.id }) { local.plates.append(plate) }
            }
        }
        struct Plan: Decodable { let active: Bool }
        let plan = try await api.rpc("crumb_my_plan", as: Plan.self)
        var plateFiles: [UUID: Data] = [:]
        for plate in local.plates {
            if let current = plates.first(where: { $0.identifier == plate.id }) { plateFiles[plate.id] = current.photo }
            else { plateFiles[plate.id] = try await download(plate.path, api: api) }
        }
        if plan.active && local != remote?.payload {
            for plate in local.plates { if let data = plateFiles[plate.id] { try await upload(data, path: plate.path, api: api) } }
            struct Input: Encodable { let p_payload: CloudAccountState; let p_revision: Int }
            _ = try await api.rpc("crumb_save_account_state", Input(p_payload: local, p_revision: remote?.revision ?? 0), as: Int.self)
        }
        guard account?.session?.userID == userID else { throw CancellationError() }
        guard defaults.string(forKey: "profileName") ?? "" == originalState.name,
              defaults.data(forKey: "profileAvatar") ?? Data() == originalState.avatar,
              defaults.string(forKey: "recipeCategories") ?? "[]" == originalState.categories,
              try context.fetch(FetchDescriptor<HomePlate>()).count == plates.count else { again = true; return }
        defaults.set(local.name, forKey: "profileName"); defaults.set(local.avatar, forKey: "profileAvatar"); defaults.set(local.categories, forKey: "recipeCategories")
        for plate in local.plates where !plates.contains(where: { $0.identifier == plate.id }) {
            guard let data = plateFiles[plate.id] else { continue }
            let value = HomePlate(photo: data); value.identifier = plate.id; value.addedAt = Date(timeIntervalSince1970: plate.date)
            value.foodX = plate.x; value.foodY = plate.y; value.foodScale = plate.scale; context.insert(value)
        }
        try context.save()
        stateBaseline = plan.active ? local : remote?.payload
        try checkpoint()
    }
    private struct Checkpoint: Codable { var books: [String: BookSnapshot]; var state: CloudAccountState? }
    private func checkpoint() throws {
        guard let cacheURL else { return }
        try JSONEncoder().encode(Checkpoint(books: baselines, state: stateBaseline)).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private struct EmptyResponse: Decodable { init(from decoder: Decoder) throws {} }
}

@MainActor
final class InviteRouter: ObservableObject {
    @Published var pending: String?
    @Published var recipeSource: String?
    static func token(from input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if let url = URL(string: raw), url.scheme == "crumb", url.host == "join" { value = url.lastPathComponent }
        else { value = raw }
        guard value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    func open(_ url: URL) {
        if let value = Self.token(from: url.absoluteString) { pending = value; return }
        if url.scheme == "crumb", url.host == "import",
           let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
           let value = URL(string: source), RecipeImport.allowed(value) { recipeSource = source }
    }
}
