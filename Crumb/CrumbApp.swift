import SwiftUI
import SwiftData
import MapKit
import CloudKit

@main
struct CrumbApp: App {
    @UIApplicationDelegateAdaptor(CrumbAppDelegate.self) private var appDelegate
    private let store = try! ModelContainer(for: Meal.self, HomePlate.self, configurations: ModelConfiguration(cloudKitDatabase: .none))

    var body: some Scene {
        WindowGroup {
            AlbumView()
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .tint(clay)

                .preferredColorScheme(.light)
        }
        .modelContainer(store)
    }
}

struct AlbumView: View {
    private static let mascotImage = Bundle.main.url(forResource: "CrumbFace", withExtension: "png")
        .flatMap { UIImage(contentsOfFile: $0.path) }

    @Query(sort: \Meal.date, order: .reverse) private var meals: [Meal]
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicType
    @AppStorage("loadedSimulatorSamples") private var loadedSamples = false
    private enum Tab { case collection, calendar, map }
    @State private var activeTab: Tab = .map
    @State private var calendarDate = Date.now
    @State private var filter: Filter = .all
    @State private var poster: ShareCard?
    @State private var posterError = false

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "すべて"
        case home = "おうち"
        case out = "外ごはん"
        var id: Self { self }
    }

    private var visibleMeals: [Meal] {
        switch filter {
        case .all: meals.filter { $0.wantToVisit != true }
        case .home: meals.filter { $0.placeKey == Place.home.id }
        case .out: meals.filter { $0.wantToVisit != true && $0.place?.coordinate != nil }
        }
    }
    @AppStorage("crumbMealFolders") private var folderStorage = Data()
    @State private var sharedOwnedFolders: Set<UUID> = []
    @State private var invitedFolders: [InvitedMap] = []
    private enum CollectionScope: String, CaseIterable {
        case you = "You"
        case shared = "Shared"
    }

    @State private var collectionScope: CollectionScope = .you
    @State private var browsingMeals = false
    @State private var selectedFolder: CKRecordZone.ID?
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var folderError = false
    @State private var folderRefreshVersion = 0

    private var folders: [PersonalMap] {
        (try? JSONDecoder().decode([PersonalMap].self, from: folderStorage)) ?? []
    }

    private func saveFolders(_ folders: [PersonalMap]) {
        if let data = try? JSONEncoder().encode(folders) { folderStorage = data }
    }

    @State private var adding = false
    @State private var sampleError = false

    var body: some View {
        NavigationStack {
            Group {
                if activeTab == .map {
                    MapLibrary(meals: meals)
                } else if activeTab == .calendar {
                    MealCalendar(meals: meals.filter { $0.wantToVisit != true }, selectedDate: $calendarDate) { adding = true }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("crumb")
                                .font(crumbFont(39))
                                .accessibilityAddTraits(.isHeader)
                            if let mascot = Self.mascotImage {
                                Image(uiImage: mascot)
                                    .resizable().scaledToFit()
                                    .frame(width: 40, height: 40)
                                    .accessibilityHidden(true)
                            }
                            Spacer(minLength: 4)
                            if browsingMeals && selectedFolder == nil && !visibleMeals.isEmpty {
                                Button(action: shareCollection) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(.body).weight(.semibold))
                                        .frame(width: 44, height: 44)
                                        .background(ink.opacity(0.05), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("コレクションを共有")
                            }
                            Menu {
                                Button("記録する", systemImage: "camera") { adding = true }
                                Button("フォルダを作成", systemImage: "folder.badge.plus") {
                                    folderName = ""
                                    creatingFolder = true
                                }
                            } label: {
                                Image(systemName: "plus").font(.body.weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .foregroundStyle(.white).background(ink, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("追加")
                        }
                        .padding(.horizontal, 20).padding(.vertical, 14)

                        collectionTabs
                        if selectedFolder != nil || browsingMeals {
                            Button {
                                selectedFolder = nil
                                browsingMeals = false
                            } label: {
                                Label(collectionTitle, systemImage: "chevron.left")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("コレクション一覧に戻る")
                            .padding(.horizontal, 22)
                        }
                        if let zone = selectedFolder {
                            MealFolderDetail(
                                owned: folders.first { MapCloud.folderZone($0.id) == zone },
                                zone: zone, meals: meals, refreshVersion: folderRefreshVersion,
                                onChange: { updated in saveFolders(folders.map { $0.id == updated.id ? updated : $0 }) },
                                onDelete: {
                                    saveFolders(folders.filter { MapCloud.folderZone($0.id) != zone })
                                    sharedOwnedFolders = sharedOwnedFolders.intersection(folders.map(\.id))
                                    selectedFolder = nil
                                }
                            )
                            .id(zone)
                        } else if !browsingMeals {
                            collectionList
                        } else if visibleMeals.isEmpty {
                            ContentUnavailableView(
                                meals.isEmpty ? "まだ料理がありません" : "この場所の記録がありません",
                                systemImage: "fork.knife",
                                description: meals.isEmpty ? Text("右上の＋から写真を追加できます。") : nil
                            )
                        } else {
                            ScrollView {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                                                 count: dynamicType.isAccessibilitySize ? 2 : 3),
                                          spacing: 26) {
                                    ForEach(visibleMeals) { meal in
                                        NavigationLink(value: meal) { AlbumTile(meal: meal) }
                                            .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 82)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(ink)
            .background { AlbumPaper().ignoresSafeArea() }
            .overlay(alignment: .bottom) {
                HStack(spacing: 10) {
                    tab("コレクション", icon: "book.closed", destination: .collection)
                    tab("カレンダー", icon: "calendar", destination: .calendar)
                    tab("マップ", icon: "map", destination: .map)
                }
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background(.white, in: Capsule())
                .shadow(color: ink.opacity(0.15), radius: 12, y: 5)
                .padding(.bottom, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Meal.self) { MealDetail(meal: $0) }
            .sheet(isPresented: $adding) {
                let zone = activeTab == .collection ? selectedFolder : nil
                MealEditor(meal: nil, initialDate: activeTab == .calendar ? calendarDate : nil) { meal in
                    guard let zone else { return }
                    Task { await addNewMeal(meal, to: zone) }
                }
            }
            .alert("フォルダを作成", isPresented: $creatingFolder) {
                TextField("フォルダ名", text: $folderName)
                Button("キャンセル", role: .cancel) {}
                Button("作成") {
                    let folder = PersonalMap(title: folderName.trimmingCharacters(in: .whitespacesAndNewlines), mealIDs: [])
                    saveFolders(folders + [folder])
                    collectionScope = .you
                    selectedFolder = MapCloud.folderZone(folder.id)
                }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("フォルダに追加できませんでした", isPresented: $folderError) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text("食事はコレクションに保存済みです。共有するには参加者の権限を確認してください。オーナーは「参加者を招待」から同期を再試行できます。")
            }
            .sheet(item: $poster) { SharePreview(card: $0) }
            .alert("画像を作成できませんでした", isPresented: $posterError) {
                Button("閉じる", role: .cancel) {}
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .crumbShareAccepted)) { _ in activeTab = .map }
        .onReceive(NotificationCenter.default.publisher(for: .crumbFolderAccepted)) { _ in
            activeTab = .collection
            Task { await loadFolders(selectNew: true) }
        }
        .task { await loadFolders() }
        .task {
            #if targetEnvironment(simulator)
            guard !loadedSamples else { return }
            do {
                if meals.isEmpty { try Samples.insert(into: context) }
                loadedSamples = true
            } catch {
                context.rollback()
                sampleError = true
            }
            #endif
        }
        .alert("サンプルを読み込めませんでした", isPresented: $sampleError) {
            Button("閉じる", role: .cancel) {}
        }
    }

    private var collectionTabs: some View {
        Picker("コレクションの表示", selection: Binding(
            get: { collectionScope },
            set: { scope in
                collectionScope = scope
                selectedFolder = nil
                browsingMeals = false
                if scope == .shared { Task { await loadFolders() } }
            }
        )) {
            ForEach(CollectionScope.allCases, id: \.self) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)

    }

    private var collectionTitle: String {
        guard let zone = selectedFolder else { return filter.rawValue }
        return folders.first { MapCloud.folderZone($0.id) == zone }?.title
            ?? invitedFolders.first { $0.id == zone }?.title
            ?? "コレクション"
    }

    private var collectionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if collectionScope == .you {
                    ForEach(Filter.allCases) { option in
                        collectionRow(option.rawValue, icon: option == .all ? "book.closed" : option == .home ? "house" : "fork.knife") {
                            filter = option
                            browsingMeals = true
                        }
                    }
                    ForEach(folders) { folder in
                        collectionRow(folder.title, icon: "folder") { selectedFolder = MapCloud.folderZone(folder.id) }
                    }
                } else if invitedFolders.isEmpty && sharedOwnedFolders.isEmpty {
                    ContentUnavailableView("共有コレクションはまだありません", systemImage: "person.2")
                } else {
                    ForEach(folders.filter { sharedOwnedFolders.contains($0.id) }) { folder in
                        collectionRow(folder.title, icon: "person.2") { selectedFolder = MapCloud.folderZone(folder.id) }
                    }
                    ForEach(invitedFolders) { folder in
                        collectionRow(folder.title, icon: "person.2") { selectedFolder = folder.id }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 82)
        }
    }

    @ViewBuilder private func collectionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .frame(width: 40, height: 40)
                    .background(ink.opacity(0.05), in: .rect(cornerRadius: 10))
                Text(title).font(.body.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider()
    }

    private func loadFolders(selectNew: Bool = false) async {
        guard MapCloud.enabled else { return }
        let database = MapCloud.container.privateCloudDatabase
        for folder in folders {
            do {
                if try await MapCloud.existingShare(in: MapCloud.folderZone(folder.id), database: database) != nil {
                    sharedOwnedFolders.insert(folder.id)
                } else {
                    sharedOwnedFolders.remove(folder.id)
                }
            } catch {
                continue
            }
        }
        guard let updated = try? await MapCloud.invitedMaps(folder: true) else { return }
        if selectNew, let folder = updated.first(where: { item in !invitedFolders.contains { $0.id == item.id } }) {
            collectionScope = .shared
            selectedFolder = folder.id
        }
        invitedFolders = updated
    }

    private func addNewMeal(_ meal: Meal, to zone: CKRecordZone.ID) async {
        if var folder = folders.first(where: { MapCloud.folderZone($0.id) == zone }) {
            folder.mealIDs.insert(meal.id)
            saveFolders(folders.map { $0.id == folder.id ? folder : $0 })
            guard MapCloud.enabled else { return }
            let database = MapCloud.container.privateCloudDatabase
            do {
                if try await MapCloud.existingShare(in: zone, database: database) != nil {
                    try await MapCloud.add([meal], to: zone, database: database)
                }
            } catch { folderError = true }
        } else if MapCloud.enabled {
            do {
                try await MapCloud.add([meal], to: zone, database: MapCloud.container.sharedCloudDatabase)
                folderRefreshVersion += 1
            } catch { folderError = true }
        }
    }

    @MainActor private func shareCollection() {
        let entries = visibleMeals
        let title = filter == .all ? "crumb" : filter.rawValue
        let renderer = ImageRenderer(content:
            VStack(spacing: 22) {
                VStack(spacing: 5) {
                    Text(title).font(filter == .all ? crumbFont(28) : .system(size: 28, weight: .bold))
                    Text("\(entries.count)件").font(.system(size: 13)).foregroundStyle(ink.opacity(0.65))
                }
                Grid(alignment: .top, horizontalSpacing: 7, verticalSpacing: 13) {
                    ForEach(Array(stride(from: 0, to: entries.count, by: 5)), id: \.self) { start in
                        GridRow {
                            ForEach(entries[start..<min(start + 5, entries.count)]) { meal in
                                VStack(spacing: 4) {
                                    PlatePhoto(meal: meal, pixels: 190).frame(width: 62, height: 62)
                                    Text(meal.title).font(.system(size: 9, weight: .medium))
                                        .lineLimit(2).multilineTextAlignment(.center)
                                }
                                .frame(width: 62)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 17).padding(.vertical, 29)
            .frame(width: 380)
            .background { AlbumPaper() }
        )
        renderer.scale = 2
        if let image = renderer.uiImage {
            poster = ShareCard(image: image, description: "\(title) · \(entries.count)件")
        } else {
            posterError = true
        }
    }

    private func tab(_ title: String, icon: String, destination: Tab) -> some View {
        Button { activeTab = destination } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                Text(title).font(.system(.caption2).weight(.medium))
            }
            .frame(minWidth: 62, minHeight: 49)
            .foregroundStyle(activeTab == destination ? clay : ink.opacity(0.62))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(activeTab == destination ? .isSelected : [])
    }
}

struct AlbumTile: View {
    let meal: Meal

    var body: some View {
        VStack(spacing: 5) {
            PlatePhoto(meal: meal, pixels: 420)
                .aspectRatio(1, contentMode: .fit)
            Text(meal.title)
                .font(.system(.subheadline).weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.top, 3)
            if let date = meal.recordedDate {
                Text(dayLabel(date))
                .font(.system(.caption2))
                .foregroundStyle(ink.opacity(0.63))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meal-\(meal.title)")
    }
}

struct PlatePhoto: View {
    let meal: Meal
    let pixels: Int

    var body: some View {
        let photo = MealPhoto(data: meal.photo, size: pixels, contentMode: .fit)
        if meal.photo.isPlatedPhoto {
            photo.shadow(color: ink.opacity(0.22), radius: 3, x: 0, y: 2)
        } else {
            photo.clipShape(.rect(cornerRadius: 10))
        }
    }
}

struct AlbumPaper: View {
    var body: some View {
        paper
            .overlay {
                Canvas { context, size in
                    for index in 0..<Int(size.width * size.height / 3800) {
                        let x = (Double(index * 73 % 211) / 211) * size.width
                        let y = (Double(index * 137 % 293) / 293) * size.height
                        let fiber = Path { path in
                            path.move(to: CGPoint(x: x, y: y))
                            path.addLine(to: CGPoint(x: x + Double(index % 5) - 2, y: y + 3))
                        }
                        context.stroke(fiber, with: .color(clay.opacity(0.09)), lineWidth: 0.65)
                    }
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
    }
}
