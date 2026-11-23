import SwiftUI
import CloudKit
import SwiftData
import CryptoKit

struct PersonalMap: Codable, Identifiable {
    var id = UUID()
    var title: String
    var mealIDs: Set<UUID>
}

struct InvitedMap: Identifiable {
    let id: CKRecordZone.ID
    let title: String
    let canEdit: Bool
}

enum MapCloud {
    static let identifier = "iCloud.app.tabinote.meals"
    static var container: CKContainer { CKContainer(identifier: identifier) }

    static var enabled: Bool {
        #if targetEnvironment(simulator) || CRUMB_DEVICE_PREVIEW
        false
        #else
        true
        #endif
    }

    static func zone(for map: PersonalMap) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "crumb-\(map.id.uuidString)", ownerName: CKCurrentUserDefaultName)
    }

    static func folderZone(_ id: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "crumbfolder-\(id.uuidString)", ownerName: CKCurrentUserDefaultName)
    }

    static func existingShare(in zoneID: CKRecordZone.ID, database: CKDatabase) async throws -> CKShare? {
        do {
            let root = try await database.record(for: CKRecord.ID(recordName: "map", zoneID: zoneID))
            guard let reference = root.share else { return nil }
            return try await database.record(for: reference.recordID) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound || error.code == .userDeletedZone {
            return nil
        }
    }

    static func invite(_ map: PersonalMap, meals: [Meal], folder: Bool = false) async throws -> CKShare {
        let database = container.privateCloudDatabase
        let zoneID = folder ? folderZone(map.id) : zone(for: map)
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        let rootID = CKRecord.ID(recordName: "map", zoneID: zoneID)
        let root: CKRecord
        do {
            root = try await database.record(for: rootID)
        } catch let error as CKError where error.code == .unknownItem {
            root = CKRecord(recordType: "CrumbMap", recordID: rootID)
            root["title"] = map.title
        }
        if let reference = root.share,
           let existing = try await database.record(for: reference.recordID) as? CKShare {
            try await add(meals, to: zoneID, database: database, defaultAuthor: folder ? nil : "オーナー")
            return existing
        }
        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = map.title
        share.publicPermission = .none
        let result = try await database.modifyRecords(saving: [root, share], deleting: [])
        guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await add(meals, to: zoneID, database: database, defaultAuthor: folder ? nil : "オーナー")
        return saved
    }

    static func add(_ meals: [Meal], to zoneID: CKRecordZone.ID, database: CKDatabase, defaultAuthor: String? = nil) async throws {
        for meal in meals {
            let place = meal.place
            let coordinate = place?.coordinate
            guard coordinate != nil || meal.wantToVisit == true || zoneID.zoneName.hasPrefix("crumbfolder-") else { continue }
            let recordID = CKRecord.ID(recordName: meal.id.uuidString, zoneID: zoneID)
            do {
                if meal.wantToVisit == true {
                    try await mergePin(meal, recordID: recordID, database: database)
                } else {
                    try await syncRecipe(meal, recordID: recordID, database: database)
                }
                continue
            } catch let error as CKError where error.code == .unknownItem {}
            let rootID = CKRecord.ID(recordName: "map", zoneID: zoneID)
            let record = CKRecord(recordType: "CrumbMapMeal", recordID: recordID)
            record.setParent(rootID)
            record["name"] = meal.name
            record["date"] = meal.date
            record["dateOmitted"] = meal.dateOmitted == true ? 1 : 0
            writeRecipe(meal, to: record)
            if let place {
                record["placeName"] = place.name
                record["placeKey"] = place.id
                record["placeAddress"] = place.address
            }
            if let coordinate {
                record["coordinate"] = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
            record["note"] = meal.note
            record["wantToVisit"] = meal.wantToVisit == true ? 1 : 0
            if let sourceURL = meal.sourceURL { record["sourceURL"] = sourceURL }
            if let links = meal.additionalSourceURLs { record["additionalSourceURLs"] = links }
            if let author = meal.addedBy ?? defaultAuthor { record["addedBy"] = author }
            if let visited = meal.visited { record["visited"] = visited ? 1 : 0 }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try meal.photo.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            record["photo"] = CKAsset(fileURL: file)
            do {
                _ = try await database.save(record)
            } catch let error as CKError where error.code == .serverRecordChanged {
                if meal.wantToVisit == true {
                    try await mergePin(meal, recordID: recordID, database: database)
                } else {
                    try await syncRecipe(meal, recordID: recordID, database: database)
                }
            }
        }
    }

    private static func mergePin(_ meal: Meal, recordID: CKRecord.ID, database: CKDatabase) async throws {
        for attempt in 0..<3 {
            let record = try await database.record(for: recordID)
            let stored = [record["sourceURL"] as? String, record["additionalSourceURLs"] as? String]
                .compactMap { $0 }.flatMap { $0.split(separator: "\n").map(String.init) }
            var seen = Set<String>()
            let links = (stored + meal.instagramLinks.map(\.absoluteString)).filter { seen.insert($0).inserted }
            if let first = links.first { record["sourceURL"] = first }
            record["additionalSourceURLs"] = links.dropFirst().joined(separator: "\n")
            if let visited = meal.visited { record["visited"] = visited ? 1 : 0 }
            if record["addedBy"] == nil, let author = meal.addedBy { record["addedBy"] = author }
            do {
                _ = try await database.save(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 {
                continue
            }
        }
    }

    private static func writeRecipe(_ meal: Meal, to record: CKRecord) {
        record["recipe"] = meal.recipe
        record["structuredRecipe"] = meal.structuredRecipe
        record["recipeURL"] = meal.recipeURL
        record["recipeUpdatedAt"] = meal.recipeUpdatedAt ?? .distantPast
    }

    private static func syncRecipe(_ meal: Meal, recordID: CKRecord.ID, database: CKDatabase) async throws {
        for attempt in 0..<3 {
            let record = try await database.record(for: recordID)
            let localDate = meal.recipeUpdatedAt ?? .distantPast
            if let remoteDate = record["recipeUpdatedAt"] as? Date, remoteDate >= localDate { return }
            writeRecipe(meal, to: record)
            do {
                _ = try await database.save(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 {
                continue
            }
        }
    }

    @MainActor static func syncPublishedRecipe(_ meal: Meal) async throws {
        guard enabled else { return }
        let stored = UserDefaults.standard.data(forKey: "crumbPersonalMaps") ?? Data()
        let maps = (try? JSONDecoder().decode([PersonalMap].self, from: stored)) ?? []
        let folderData = UserDefaults.standard.data(forKey: "crumbMealFolders") ?? Data()
        let folders = (try? JSONDecoder().decode([PersonalMap].self, from: folderData)) ?? []
        let ownedZones = maps.filter { $0.mealIDs.contains(meal.id) }.map(zone(for:))
            + folders.filter { $0.mealIDs.contains(meal.id) }.map { folderZone($0.id) }
        let privateDB = container.privateCloudDatabase
        let sharedDB = container.sharedCloudDatabase
        var firstFailure: Error?
        for zone in ownedZones {
            do {
                try await syncRecipe(meal, recordID: CKRecord.ID(recordName: meal.id.uuidString, zoneID: zone),
                                     database: privateDB)
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound || error.code == .userDeletedZone {
                continue
            } catch { firstFailure = firstFailure ?? error }
        }
        let incoming = try await sharedDB.allRecordZones()
        for zone in incoming where zone.zoneID.zoneName.hasPrefix("crumb-") || zone.zoneID.zoneName.hasPrefix("crumbfolder-") {
            do {
                try await syncRecipe(meal, recordID: CKRecord.ID(recordName: meal.id.uuidString, zoneID: zone.zoneID),
                                     database: sharedDB)
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                continue
            } catch { firstFailure = firstFailure ?? error }
        }
        if let firstFailure { throw firstFailure }
    }

    static func invitedMaps(folder: Bool = false) async throws -> [InvitedMap] {
        let database = container.sharedCloudDatabase
        var maps: [InvitedMap] = []
        for zone in try await database.allRecordZones() where zone.zoneID.zoneName.hasPrefix(folder ? "crumbfolder-" : "crumb-") {
            let id = CKRecord.ID(recordName: "map", zoneID: zone.zoneID)
            do {
                let record = try await database.record(for: id)
                if let title = record["title"] as? String {
                    let share = try await existingShare(in: zone.zoneID, database: database)
                    maps.append(InvitedMap(id: zone.zoneID, title: title,
                                           canEdit: share?.currentUserParticipant?.permission == .readWrite))
                }
            } catch let error as CKError where error.code == .unknownItem || error.code == .permissionFailure {
                continue
            }
        }
        return maps.sorted { $0.title < $1.title }
    }

    static func meals(in zone: CKRecordZone.ID, database: CKDatabase) async throws -> [Meal] {
        var token: CKServerChangeToken?
        var records: [CKRecord.ID: CKRecord] = [:]
        repeat {
            let page = try await database.recordZoneChanges(inZoneWith: zone, since: token)
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                if record.recordType == "CrumbMapMeal" { records[id] = record }
            }
            for deletion in page.deletions { records[deletion.recordID] = nil }
            token = page.moreComing ? page.changeToken : nil
        } while token != nil
        return try records.values.map { record in
            guard let url = (record["photo"] as? CKAsset)?.fileURL,
                  let date = record["date"] as? Date else { throw CocoaError(.fileReadCorruptFile) }
            let location = record["coordinate"] as? CLLocation
            let place: Place?
            if let key = record["placeKey"] as? String, let name = record["placeName"] as? String {
                place = Place(id: key, name: name, address: record["placeAddress"] as? String ?? "",
                              latitude: location?.coordinate.latitude, longitude: location?.coordinate.longitude)
            } else {
                place = nil
            }
            let meal = Meal(photo: try Data(contentsOf: url), name: record["name"] as? String ?? "", date: date, place: place)
            meal.note = record["note"] as? String ?? ""
            meal.wantToVisit = (record["wantToVisit"] as? Int) == 1
            meal.sourceURL = record["sourceURL"] as? String
            meal.additionalSourceURLs = record["additionalSourceURLs"] as? String
            meal.addedBy = record["addedBy"] as? String
            meal.visited = (record["visited"] as? Int).map { $0 == 1 }
            meal.dateOmitted = (record["dateOmitted"] as? Int) == 1
            meal.structuredRecipe = record["structuredRecipe"] as? String
            meal.recipe = record["recipe"] as? String ?? ""
            meal.recipeURL = record["recipeURL"] as? String ?? ""
            meal.recipeUpdatedAt = record["recipeUpdatedAt"] as? Date
            if let id = UUID(uuidString: record.recordID.recordName) { meal.id = id }
            return meal
        }.sorted { $0.date > $1.date }
    }
}

extension Notification.Name {
    static let crumbFolderAccepted = Notification.Name("crumbFolderAccepted")
    static let crumbShareAccepted = Notification.Name("crumbShareAccepted")
}

final class CrumbAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = CrumbSceneDelegate.self
        return configuration
    }
}

final class CrumbSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let metadata = options.cloudKitShareMetadata { accept(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        accept(metadata)
    }

    private func accept(_ metadata: CKShare.Metadata) {
        guard MapCloud.enabled else { return }
        Task { @MainActor in
            do {
                if metadata.participantStatus != .accepted {
                    let results = try await MapCloud.container.accept([metadata])
                    guard let result = results[metadata] else { throw CocoaError(.fileReadUnknown) }
                    _ = try result.get()
                }
                let isFolder = metadata.share.recordID.zoneID.zoneName.hasPrefix("crumbfolder-")
                NotificationCenter.default.post(name: isFolder ? .crumbFolderAccepted : .crumbShareAccepted, object: nil)
            } catch {
                NotificationCenter.default.post(name: .crumbShareAccepted, object: error)
            }
        }
    }
}

struct MapInvitation: Identifiable {
    let share: CKShare
    var id: CKRecord.ID { share.recordID }
}

struct MapInviteSheet: UIViewControllerRepresentable {
    let invitation: MapInvitation
    let onError: (Error) -> Void

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: invitation.share, container: MapCloud.container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite, .allowReadOnly]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let sheet: MapInviteSheet
        init(_ sheet: MapInviteSheet) { self.sheet = sheet }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            sheet.invitation.share[CKShare.SystemFieldKey.title] as? String
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            sheet.onError(error)
        }
    }
}

struct MapLibrary: View {
    let meals: [Meal]
    @Environment(\.scenePhase) private var phase
    @AppStorage("crumbPersonalMaps") private var storedMaps = Data()
    @State private var current: Choice = .mine
    @State private var invited: [InvitedMap] = []
    @State private var downloaded: [Meal] = []
    @State private var loadedChoice: Choice?
    @State private var creating = false
    @Environment(\.modelContext) private var context
    @State private var showingVisited = false
    @State private var savedPlacesOpen = false
    @State private var addingPin = false
    @State private var importingDraft = false
    @State private var instagramDraft: InstagramDraft?
    @State private var pinDestination: Choice = .mine
    @AppStorage("crumbLastPinMap") private var lastPinMap = "mine"
    @State private var addingMeals = false
    @State private var composingCard = false
    @State private var busy = false
    @State private var invitation: MapInvitation?
    @State private var viewingLink: URL?
    @State private var failure: String?
    @State private var refresh = UUID()

    private struct MapDisplay: Hashable {
        let choice: Choice
        let showingVisited: Bool
    }

    private enum Choice: Hashable {
        case mine
        case personal(UUID)
        case invited(CKRecordZone.ID)
    }

    private var maps: [PersonalMap] {
        (try? JSONDecoder().decode([PersonalMap].self, from: storedMaps)) ?? []
    }

    private var ownedMap: PersonalMap? {
        guard case let .personal(id) = current else { return nil }
        return maps.first { $0.id == id }
    }

    private var title: String {
        switch current {
        case .mine: "行きたいお店"
        case .personal: ownedMap?.title ?? "マップ"
        case .invited(let id): invited.first { $0.id == id }?.title ?? "共有マップ"
        }
    }

    private var mappedMeals: [Meal] {
        let remote = loadedChoice == current ? downloaded : []
        switch current {
        case .mine:
            return meals
        case .personal:
            let local = meals.filter { ownedMap?.mealIDs.contains($0.id) == true }
            let localIDs = Set(local.map(\.id))
            return (local + remote.filter { !localIDs.contains($0.id) }).sorted { $0.date > $1.date }
        case .invited:
            return remote
        }
    }

    private var hasPins: Bool { mappedMeals.contains { $0.place?.coordinate != nil && (showingVisited ? ($0.wantToVisit != true || $0.visited == true) : ($0.wantToVisit == true && $0.visited != true)) } }

    var body: some View {
        MealMap(meals: mappedMeals.filter { showingVisited ? ($0.wantToVisit != true || $0.visited == true) : ($0.wantToVisit == true && $0.visited != true) }, canEditMeals: current == .mine, composingMap: $composingCard, pinDetail: { pin in
            WantedPlaceDetail(pin: pin, canEdit: canEditCurrent, sharedScope: memoryScope) {
                try await updatePin(pin)
            }
        })
            .id(MapDisplay(choice: current, showingVisited: showingVisited))
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    HStack {
                        Menu {
                            Button("行きたいお店") { current = .mine }
                            ForEach(maps) { map in
                                Button(map.title) { current = .personal(map.id) }
                            }
                            ForEach(invited) { map in
                                Button(map.title) { current = .invited(map.id) }
                            }
                            Divider()
                            Button("新しいマップ", systemImage: "plus") { creating = true }
                            if MapCloud.enabled {
                                Button("更新", systemImage: "arrow.clockwise") {
                                    refresh = UUID()
                                    Task { await loadInvited(reportErrors: true) }
                                }
                            }
                        } label: {
                            Label(title, systemImage: "chevron.down").lineLimit(1)
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .background(.white, in: Capsule())
                        }
                        Spacer()
                        Menu {
                            Button("共有マップを作る", systemImage: "person.2") { creating = true }
                            if ownedMap != nil {
                                Button("人を招待", systemImage: "person.badge.plus") {
                                    Task { await invite() }
                                }
                                Button("閲覧用リンクを作る", systemImage: "link") {
                                    Task { await publishViewingMap() }
                                }
                            }
                            if current != .mine && canEditCurrent {
                                Button("保存済みのピンを追加", systemImage: "plus") { addingMeals = true }
                            }
                            if hasPins {
                                Button("画像カードを作る", systemImage: "photo") { composingCard = true }
                            }

                        } label: {
                            Image(systemName: "ellipsis").font(.headline)
                                .frame(width: 44, height: 44)
                                .background(.white, in: Circle())
                                .accessibilityLabel("マップの操作")
                        }
                        .disabled(busy)
                    }
                    Button {
                        beginPin()
                    } label: {
                        Label("店名で検索・投稿リンクを保存", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            .padding(.horizontal, 15)
                            .background(.white, in: .rect(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    HStack(spacing: 8) {
                        mapFilter("行きたい", symbol: "bookmark", visited: false)
                        mapFilter("食事の記録", symbol: "fork.knife", visited: true)
                        Spacer()
                    }
                    Button("保存済み一覧", systemImage: "list.bullet") { savedPlacesOpen = true }
                        .font(.subheadline.weight(.medium))
                        .padding(9).background(.white, in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if busy { ProgressView().padding(8).background(.white, in: Capsule()) }
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 18).padding(.top, 8)
            }
            .sheet(isPresented: $savedPlacesOpen) {
                NavigationStack {
                    List(mappedMeals.filter { $0.wantToVisit == true }) { pin in
                        NavigationLink {
                            WantedPlaceDetail(pin: pin, canEdit: canEditCurrent, sharedScope: memoryScope) {
                                try await updatePin(pin)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(pin.title)
                                if let address = pin.placeAddress, !address.isEmpty {
                                    Text(address).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationTitle("保存済みのお店")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("閉じる") { savedPlacesOpen = false } }
                }
            }
            .sheet(isPresented: $addingPin) {
                WantedPinEditor(draft: instagramDraft, destinationPicker: AnyView(
                    Picker("保存先", selection: $pinDestination) {
                        Text("行きたいお店").tag(Choice.mine)
                        ForEach(maps) { map in Text(map.title).tag(Choice.personal(map.id)) }
                        ForEach(invited.filter(\.canEdit)) { map in Text(map.title).tag(Choice.invited(map.id)) }
                    }
                )) { pin in
                    try await savePin(pin, to: pinDestination)
                    instagramDraft?.remove()
                    instagramDraft = nil
                    showingVisited = false
                    current = pinDestination
                } onDiscard: {
                    instagramDraft?.remove()
                    instagramDraft = nil
                }
            }
            .sheet(isPresented: $creating) {
                MapMealPicker(meals: meals, creating: true) { title, ids in
                    let map = PersonalMap(title: title, mealIDs: ids)
                    save(maps + [map])
                    current = .personal(map.id)
                }
            }
            .sheet(isPresented: $addingMeals) {
                MapMealPicker(meals: meals, creating: false) { _, ids in
                    Task { await add(ids) }
                }
            }
            .sheet(isPresented: Binding(get: { viewingLink != nil }, set: { if !$0 { viewingLink = nil } })) {
                if let viewingLink {
                    VStack(spacing: 16) {
                        Text("閲覧用マップ").font(.headline)
                        Text("リンクを知っている人に、お店とおすすめメモを共有します。")
                            .font(.subheadline).multilineTextAlignment(.center)
                        ShareLink(item: viewingLink)
                    }
                    .padding(24)
                    .presentationDetents([.medium])
                }
            }
            .sheet(item: $invitation) { invitation in
                MapInviteSheet(invitation: invitation) { error in
                    self.invitation = nil
                    failure = error.localizedDescription
                }
            }
            .alert("マップ", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("閉じる", role: .cancel) {}
            } message: { Text(failure ?? "") }
            .task { await loadInvited(); resumeDraft() }
            .onChange(of: storedMaps) { exportDestinations() }
            .task(id: current) { await loadCurrent() }
            .task(id: refresh) { await loadCurrent() }
            .task(id: current) {
                guard MapCloud.enabled, current != .mine else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(20)) }
                    catch { return }
                    if phase == .active { await loadCurrent() }
                }
            }
            .onChange(of: phase) { _, phase in
                if phase == .active {
                    refresh = UUID()
                    Task { await loadInvited(); resumeDraft() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .crumbShareAccepted)) { notification in
                if let error = notification.object as? Error {
                    failure = error.localizedDescription
                } else {
                    Task { await loadInvited(reportErrors: true) }
                }
            }
    }

    private var canEditCurrent: Bool {
        switch current {
        case .mine, .personal: true
        case .invited(let zone): invited.first { $0.id == zone }?.canEdit == true
        }
    }

    private var memoryScope: SharedVisits? {
        guard MapCloud.enabled else { return nil }
        if let ownedMap {
            return SharedVisits(zone: MapCloud.zone(for: ownedMap),
                                database: MapCloud.container.privateCloudDatabase, canUpload: true)
        }
        if case .invited(let zone) = current, !zone.zoneName.hasPrefix("crumb-view-") {
            return SharedVisits(zone: zone, database: MapCloud.container.sharedCloudDatabase, canUpload: canEditCurrent)
        }
        return nil
    }

    private func publishViewingMap() async {
        guard let map = ownedMap, !busy else { return }
        guard MapCloud.enabled else { failure = "閲覧用リンクにはiCloud対応のcrumbが必要です。"; return }
        busy = true
        defer { busy = false }
        do {
            let database = MapCloud.container.privateCloudDatabase
            let zone = CKRecordZone.ID(zoneName: "crumb-view-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)
            _ = try await database.save(CKRecordZone(zoneID: zone))
            do {
                let root = CKRecord(recordType: "CrumbMap", recordID: CKRecord.ID(recordName: "map", zoneID: zone))
                root["title"] = map.title
                _ = try await database.save(root)
                let copies = mappedMeals.filter { $0.wantToVisit == true }.map { pin in
                    let copy = Meal(photo: pin.photo, name: pin.name, date: pin.date, place: pin.place)
                    copy.wantToVisit = true
                    copy.dateOmitted = true
                    copy.note = pin.note
                    return copy
                }
                try await MapCloud.add(copies, to: zone, database: database)
                let share = CKShare(rootRecord: root)
                share[CKShare.SystemFieldKey.title] = map.title
                share.publicPermission = .readOnly
                let result = try await database.modifyRecords(saving: [root, share], deleting: [], atomically: true)
                guard let saved = try result.saveResults[share.recordID]?.get() as? CKShare,
                      let url = saved.url else { throw CocoaError(.fileWriteUnknown) }
                viewingLink = url
            } catch {
                _ = try? await database.deleteRecordZone(withID: zone)
                throw error
            }
        } catch { failure = error.localizedDescription }
    }

    private func updatePin(_ pin: Meal) async throws {
        if case .invited(let zone) = current {
            guard canEditCurrent else { throw CocoaError(.fileWriteNoPermission) }
            try await MapCloud.add([pin], to: zone, database: MapCloud.container.sharedCloudDatabase)
            refresh = UUID()
            return
        }
        if let map = ownedMap, MapCloud.enabled {
            let zone = MapCloud.zone(for: map)
            let database = MapCloud.container.privateCloudDatabase
            if try await MapCloud.existingShare(in: zone, database: database) != nil {
                try await MapCloud.add([pin], to: zone, database: database)
            }
        }
        try context.save()
    }

    private var writableChoices: [Choice] {
        [.mine] + maps.map { Choice.personal($0.id) } + invited.filter(\.canEdit).map { Choice.invited($0.id) }
    }

    private func exportDestinations() {
        let entries = [InstagramDraft.Destination(id: "mine", title: "行きたいお店")]
            + maps.map { InstagramDraft.Destination(id: choiceKey(.personal($0.id)), title: $0.title) }
            + invited.filter(\.canEdit).map { InstagramDraft.Destination(id: choiceKey(.invited($0.id)), title: $0.title) }
        InstagramDraft.updateDestinations(entries, lastMap: lastPinMap)
    }

    private func resumeDraft() {
        exportDestinations()
        guard !addingPin, !importingDraft, let draft = InstagramDraft.pending().first else { return }
        if let confirmation = draft.confirmation,
           let destination = writableChoices.first(where: { choiceKey($0) == confirmation.mapID }),
           let pin = makeWantedPin(
               place: Place(id: wantedPlaceKey(confirmation.name, confirmation.latitude, confirmation.longitude),
                            name: confirmation.name, address: confirmation.address,
                            latitude: confirmation.latitude, longitude: confirmation.longitude, isVenue: true),
               source: draft.url, note: draft.text
           ) {
            importingDraft = true
            Task {
                defer { importingDraft = false }
                do {
                    try await savePin(pin, to: destination)
                    draft.remove()
                    current = destination
                    showingVisited = false
                } catch {
                    instagramDraft = draft
                    beginPin()
                    pinDestination = destination
                    failure = error.localizedDescription
                }
            }
        } else {
            instagramDraft = draft
            beginPin()
        }
    }

    private func choiceKey(_ choice: Choice) -> String {
        switch choice {
        case .mine: "mine"
        case .personal(let id): id.uuidString
        case .invited(let zone): "\(zone.ownerName)/\(zone.zoneName)"
        }
    }

    private func beginPin() {
        pinDestination = writableChoices.first { choiceKey($0) == lastPinMap } ?? (canEditCurrent ? current : .mine)
        addingPin = true
    }

    private func savePin(_ pin: Meal, to destination: Choice) async throws {
        let candidates: [Meal]
        let zone: CKRecordZone.ID?
        let database: CKDatabase?
        switch destination {
        case .mine:
            candidates = meals
            zone = nil
            database = nil
        case .personal(let id):
            guard let map = maps.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
            candidates = meals.filter { map.mealIDs.contains($0.id) }
            if MapCloud.enabled {
                let mapZone = MapCloud.zone(for: map)
                let db = MapCloud.container.privateCloudDatabase
                if try await MapCloud.existingShare(in: mapZone, database: db) != nil {
                    zone = mapZone
                    database = db
                } else {
                    zone = nil
                    database = nil
                }
            } else {
                zone = nil
                database = nil
            }
        case .invited(let mapZone):
            zone = mapZone
            database = MapCloud.container.sharedCloudDatabase
            candidates = []
        }

        let remote: [Meal]
        if let zone, let database { remote = try await MapCloud.meals(in: zone, database: database) }
        else { remote = [] }
        let existing = (remote + candidates).first { candidate in
            guard candidate.wantToVisit == true else { return false }
            if candidate.placeKey == pin.placeKey { return true }
            guard let lhs = candidate.place, let rhs = pin.place,
                  let a = lhs.coordinate, let b = rhs.coordinate else { return false }
            return wantedPlaceKey(lhs.name, a.latitude, a.longitude) == wantedPlaceKey(rhs.name, b.latitude, b.longitude)
        }
        let saved = existing ?? pin
        if existing == nil, let place = pin.place {
            let key = place.coordinate.map { wantedPlaceKey(place.name, $0.latitude, $0.longitude) } ?? place.id
            let mapKey: String
            if case .personal(let id) = destination { mapKey = "crumb-\(id.uuidString)" }
            else { mapKey = zone?.zoneName ?? choiceKey(destination) }
            let digest = Array(SHA256.hash(data: Data("\(mapKey)|\(key)".utf8)))
            saved.id = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                                   digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        }
        for link in pin.instagramLinks { saved.appendInstagramLink(link) }
        if let zone, let database {
            if saved.addedBy == nil {
                let share = try await MapCloud.existingShare(in: zone, database: database)
                if let name = share?.currentUserParticipant?.userIdentity.nameComponents {
                    saved.addedBy = PersonNameComponentsFormatter.localizedString(from: name, style: .default)
                } else {
                    saved.addedBy = share?.currentUserParticipant?.role == .owner ? "オーナー" : "メンバー"
                }
            }
            try await MapCloud.add([saved], to: zone, database: database)
        }
        if case .invited = destination {
            refresh = UUID()
        } else {
            let local = candidates.first { $0.id == saved.id }
            if let local {
                for link in saved.instagramLinks { local.appendInstagramLink(link) }
            } else {
                context.insert(saved)
            }
            do { try context.save() }
            catch { context.rollback(); throw error }
            if case .personal(let id) = destination {
                save(maps.map { map in
                    var updated = map
                    if updated.id == id { updated.mealIDs.insert(saved.id) }
                    return updated
                })
            }
            refresh = UUID()
        }
        lastPinMap = choiceKey(destination)
        exportDestinations()
    }

    private func mapFilter(_ title: String, symbol: String, visited: Bool) -> some View {
        let selected = showingVisited == visited
        return Button {
            showingVisited = visited
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? Color.white : ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(selected ? ink : Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save(_ maps: [PersonalMap]) {
        do { storedMaps = try JSONEncoder().encode(maps) }
        catch { failure = error.localizedDescription }
    }

    @MainActor private func loadInvited(reportErrors: Bool = false) async {
        guard MapCloud.enabled else { return }
        do { invited = try await MapCloud.invitedMaps() }
        catch { if reportErrors { failure = error.localizedDescription } }
    }

    @MainActor private func loadCurrent() async {
        guard MapCloud.enabled else { return }
        let choice = current
        do {
            let result: [Meal]
            switch choice {
            case .mine:
                return
            case .personal:
                guard let map = ownedMap else { return }
                result = try await MapCloud.meals(in: MapCloud.zone(for: map), database: MapCloud.container.privateCloudDatabase)
            case .invited(let zone):
                result = try await MapCloud.meals(in: zone, database: MapCloud.container.sharedCloudDatabase)
            }
            guard !Task.isCancelled, current == choice else { return }
            downloaded = result
            loadedChoice = choice
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            if current == choice { downloaded = []; loadedChoice = nil }
        } catch {
            if !Task.isCancelled, current == choice, case .invited = choice {
                downloaded = []
                loadedChoice = nil
                failure = error.localizedDescription
            }
        }
    }

    @MainActor private func invite() async {
        guard let map = ownedMap, !busy else { return }
        guard MapCloud.enabled else {
            failure = "招待には、iCloud共有を有効にしたcrumbが必要です。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            invitation = try await MapInvitation(share: MapCloud.invite(map, meals: meals.filter { map.mealIDs.contains($0.id) }))
            await loadCurrent()
        } catch { failure = error.localizedDescription }
    }

    @MainActor private func add(_ ids: Set<UUID>, additions: [Meal]? = nil, destination: Choice? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let additions = additions ?? meals.filter { ids.contains($0.id) }
        do {
            switch destination ?? current {
            case .mine: return
            case .personal(let id):
                var updated = maps
                guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
                updated[index].mealIDs.formUnion(ids)
                save(updated)
                if MapCloud.enabled {
                    let database = MapCloud.container.privateCloudDatabase
                    let zone = MapCloud.zone(for: updated[index])
                    do {
                        let root = try await database.record(for: CKRecord.ID(recordName: "map", zoneID: zone))
                        if root.share != nil {
                            try await MapCloud.add(additions, to: zone, database: database)
                        }
                    } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {}
                }
            case .invited(let zone):
                try await MapCloud.add(additions, to: zone, database: MapCloud.container.sharedCloudDatabase)
            }
            await loadCurrent()
        } catch { failure = error.localizedDescription }
    }
}

private struct MapMealPicker: View {
    let meals: [Meal]
    let creating: Bool
    let save: (String, Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selected: Set<UUID> = []

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if creating {
                    Section("名前") { TextField("例：札幌の食べ歩き", text: $title) }
                }
                Section("載せる食事") {
                    ForEach(meals.filter { $0.place?.coordinate != nil }) { meal in
                        Toggle(isOn: Binding(get: { selected.contains(meal.id) }, set: { enabled in
                            if enabled { selected.insert(meal.id) } else { selected.remove(meal.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meal.title)
                                Text(meal.place?.name ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(creating ? "新しいマップ" : "保存済みのピンを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "作成" : "追加") {
                        save(cleanTitle, selected)
                        dismiss()
                    }
                    .disabled(creating ? cleanTitle.isEmpty : selected.isEmpty)
                }
            }
        }
    }
}

private struct WantedPinEditor: View {
    let draft: InstagramDraft?
    let destinationPicker: AnyView
    let save: (Meal) async throws -> Void
    let onDiscard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var place: Place?
    @State private var source = ""
    @State private var note = ""
    @State private var searching = false
    @State private var failed = false
    @State private var saving = false
    @State private var manualName = ""
    @State private var manualArea = ""

    private var sourceURL: URL? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "instagram.com" || host == "www.instagram.com" else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Form {
                destinationPicker
                Section("場所") {
                    Button {
                        searching = true
                    } label: {
                        VStack(alignment: .leading) {
                            Label(place?.name ?? "店名・地名で検索", systemImage: "magnifyingglass")
                            if let place, !place.address.isEmpty { Text(place.address).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if place == nil {
                    Section("手動で指定") {
                        TextField("店名", text: $manualName)
                        TextField("エリア（任意）", text: $manualArea)
                        Text("場所を確認できないお店は保存済み一覧に残ります。").font(.footnote)
                    }
                }
                Section("Instagram（任意）") {
                    TextField("投稿リンクを貼り付け", text: $source)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let url = draft?.url { InstagramPreview(url: url) { manualName = $0; searching = true } }
                    if !source.isEmpty && sourceURL == nil {
                        Text("Instagramの投稿URLを入力してください。").foregroundStyle(.secondary)
                    }
                }
                Section("メモ（任意）") {
                    TextField("気になったメニューなど", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("行きたいお店を保存")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $searching) {
                PlacePicker(selection: $place, allowsHome: false, initialQuery: [manualName, manualArea]
                    .filter { !$0.isEmpty }.joined(separator: " "))
            }
            .task(id: draft?.id) {
                if let draft {
                    source = draft.url?.absoluteString ?? ""
                    note = draft.text
                    if let confirmation = draft.confirmation {
                        place = Place(id: wantedPlaceKey(confirmation.name, confirmation.latitude, confirmation.longitude),
                                      name: confirmation.name, address: confirmation.address,
                                      latitude: confirmation.latitude, longitude: confirmation.longitude, isVenue: true)
                    }
                    manualName = draft.text.split(whereSeparator: \.isNewline).first
                        .map { String($0.prefix(80)) } ?? ""
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu("閉じる") {
                        Button("後で続ける") { dismiss() }
                        if draft != nil {
                            Button("下書きを破棄", role: .destructive) { onDiscard(); dismiss() }
                        }
                    }
                    .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let name = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let area = manualArea.trimmingCharacters(in: .whitespacesAndNewlines)
                        let chosen = place ?? Place(id: "manual:\(name.lowercased())|\(area.lowercased())",
                                                    name: name, address: area)
                        guard let pin = makeWantedPin(place: chosen, source: sourceURL, note: note) else { return }
                        saving = true
                        Task {
                            defer { saving = false }
                            do { try await save(pin); dismiss() }
                            catch { failed = true }
                        }
                    }
                    .disabled(saving || (place == nil && manualName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                              || (!source.isEmpty && sourceURL == nil))
                }
            }
            .alert("ピンを保存できませんでした", isPresented: $failed) {
                Button("閉じる", role: .cancel) {}
            }
        }
    }
}


private func wantedPlaceKey(_ name: String, _ latitude: Double, _ longitude: Double) -> String {
    "\(name.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current))|\(Int((latitude * 10_000).rounded()))|\(Int((longitude * 10_000).rounded()))"
}

@MainActor private func makeWantedPin(place: Place, source: URL?, note: String) -> Meal? {
    let photo = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { renderer in
        UIColor.white.setFill()
        renderer.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        UIImage(systemName: "fork.knife")?.draw(in: CGRect(x: 8, y: 8, width: 24, height: 24))
    }
    guard let data = photo.pngData() else { return nil }
    let pin = Meal(photo: data, name: place.name, date: .now, place: place)
    pin.wantToVisit = true
    pin.dateOmitted = true
    pin.sourceURL = source?.absoluteString
    pin.note = note
    return pin
}
