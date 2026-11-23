import SwiftUI
import PhotosUI
import Photos
import SwiftData
@preconcurrency import MapKit
import ImageIO

struct MealEditor: View {
    let meal: Meal?
    private let initialDate: Date?
    private let onSaved: ((Meal) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var item: PhotosPickerItem?
    @State private var photo: Data?
    @State private var originalPhoto: Data?
    @State private var cropSource: Data?
    @State private var showingCrop = false
    @State private var styling = false
    @State private var selectedPlateID: String?
    @State private var date: Date
    @State private var includesDate: Bool
    @State private var structured: MealRecipe
    @State private var includesRecipe: Bool
    @State private var showRecipe = false
    @State private var name: String
    @State private var note: String
    @State private var recipe: String
    @State private var recipeURL: String
    @State private var place: Place?
    @State private var loading = false
    @State private var showPlaces = false
    @State private var error: String?
    @State private var syncing = false

    init(meal: Meal?, initialDate: Date? = nil, onSaved: ((Meal) -> Void)? = nil) {
        self.meal = meal
        self.initialDate = initialDate
        self.onSaved = onSaved
        _photo = State(initialValue: meal?.photo)
        _originalPhoto = State(initialValue: meal?.originalPhoto ?? meal?.photo)
        _selectedPlateID = State(initialValue: meal?.selectedPlateID)
        _date = State(initialValue: meal?.date ?? initialDate ?? .now)
        _includesDate = State(initialValue: meal?.recordedDate != nil || initialDate != nil)
        let existingRecipe = MealRecipe(contents: meal?.structuredRecipe)
        _structured = State(initialValue: existingRecipe)
        _includesRecipe = State(initialValue: !existingRecipe.isEmpty ||
                                !(meal?.recipe.isEmpty ?? true) || !(meal?.recipeURL.isEmpty ?? true))
        _name = State(initialValue: meal?.name ?? "")
        _note = State(initialValue: meal?.note ?? "")
        _recipe = State(initialValue: meal?.recipe ?? "")
        _recipeURL = State(initialValue: meal?.recipeURL ?? "")
        _place = State(initialValue: meal?.place)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    photoHero
                    if originalPhoto != nil {
                        Button {
                            showingCrop = true
                        } label: {
                            Label("トリミング", systemImage: "crop")
                                .font(.subheadline.weight(.medium))
                                .frame(minHeight: 44)
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(loading || syncing || styling)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("料理名").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("料理名（任意）", text: $name)
                            .padding(15)
                            .background(ink.opacity(0.025), in: .rect(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ink.opacity(0.13)) }
                    }
                    if let originalPhoto {
                        PhotoPlating(original: originalPhoto, photo: $photo, working: $styling, plateID: $selectedPlateID)
                            .id(originalPhoto)
                            .disabled(loading || syncing)
                    }
                    editorSection("日付") {
                        Toggle("日付を記録", isOn: $includesDate)
                        if includesDate {
                            DatePicker("食事の日", selection: $date, displayedComponents: .date)
                        }
                    }
                    editorSection("場所") {
                        Button { showPlaces = true } label: {
                            HStack {
                                Label(place?.name ?? "場所を選ぶ", systemImage: "mappin")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    editorSection("ひとこと") {
                        TextField("メモを追加（任意）", text: $note, axis: .vertical)
                    }
                    editorSection("レシピ") {
                        Toggle("レシピを追加", isOn: $includesRecipe)
                            .onChange(of: includesRecipe) { _, enabled in
                                if enabled { showRecipe = true }
                            }
                        if includesRecipe {
                            Button { showRecipe = true } label: {
                                HStack {
                                    Text("材料と作り方を編集")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(paper.ignoresSafeArea())
            .navigationTitle(meal == nil ? "食事を追加" : "食事を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("キャンセル")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark", action: save)
                        .labelStyle(.iconOnly)
                    .disabled(photo == nil || loading || syncing || styling)
                    .accessibilityLabel("保存")
                }
            }
            .navigationDestination(isPresented: $showPlaces) { PlacePicker(selection: $place) }
            .navigationDestination(isPresented: $showRecipe) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        MealRecipeEditor(recipe: $structured)
                        if !(meal?.recipe.isEmpty ?? true) {
                            TextField("レシピメモ", text: $recipe, axis: .vertical).lineLimit(3...10)
                        }
                        TextField("レシピのURL（任意）", text: $recipeURL)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(22)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(paper.ignoresSafeArea())
                .navigationTitle("レシピ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { showRecipe = false }
                    }
                }
            }
            .sheet(isPresented: $showingCrop) {
                if let data = cropSource ?? originalPhoto, let image = UIImage(data: data) {
                    MealPhotoCropper(image: image) { cropped in
                        selectedPlateID = nil
                        originalPhoto = cropped
                        photo = cropped
                        styling = false
                    }
                }
            }
            .task(id: item) { await loadPhoto(item) }
            .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("閉じる", role: .cancel) {}
            }
        }
    }

    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.white, in: .rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ink.opacity(0.10)) }
        }
    }

    private var photoHero: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let photo {
                    MealPhoto(data: photo, size: 680, contentMode: .fit)
                } else {
                    Circle().fill(ink.opacity(0.045))
                        .overlay { Image(systemName: "fork.knife").font(.largeTitle).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 186, height: 186)
            .overlay {
                if loading || styling { ProgressView().padding(12).background(.white, in: Circle()) }
            }
            PhotosPicker(selection: $item, matching: .images, preferredItemEncoding: .current) {
                Image(systemName: "photo")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.white, in: Circle())
                    .overlay { Circle().strokeBorder(ink.opacity(0.09)) }
            }
            .disabled(loading || syncing || styling)
            .accessibilityLabel(photo == nil ? "写真を選ぶ" : "写真を変更")
        }
        .frame(maxWidth: .infinity)
    }

    private func save() {
        guard let photo, !syncing, !styling else { return }
        let record = meal ?? Meal(photo: photo, name: name, date: date, place: place)
        if meal == nil { context.insert(record) }
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.photo != photo { record.photo = photo }
        record.selectedPlateID = selectedPlateID
        record.originalPhoto = originalPhoto == photo ? nil : originalPhoto
        record.date = date
        record.dateOmitted = !includesDate
        record.note = note
        let cleanURL = includesRecipe ? recipeURL.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let recipeNote = includesRecipe ? recipe : ""
        var cleanRecipe = structured
        cleanRecipe.steps = cleanRecipe.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let contents = includesRecipe ? cleanRecipe.contents : nil
        if record.recipe != recipeNote || record.recipeURL != cleanURL ||
            MealRecipe(contents: record.structuredRecipe).contents != contents {
            record.structuredRecipe = contents
            record.recipe = recipeNote
            record.recipeURL = cleanURL
            record.recipeUpdatedAt = .now
        }
        record.setPlace(place)
        do {
            try context.save()
            onSaved?(record)
            guard MapCloud.enabled, meal != nil, record.recipeUpdatedAt != nil else {
                dismiss()
                return
            }
            syncing = true
            Task { @MainActor in
                defer { syncing = false }
                do {
                    try await MapCloud.syncPublishedRecipe(record)
                    dismiss()
                } catch {
                    self.error = "端末に保存しました。共有マップの同期に失敗しました。保存を押すと再試行できます。"
                }
            }
        } catch {
            context.rollback()
            self.error = "保存できませんでした。もう一度お試しください。"
        }
    }

    private func loadPhoto(_ candidate: PhotosPickerItem?) async {
        guard let candidate else { return }
        loading = true
        defer { if candidate == item { loading = false } }
        do {
            guard let data = try await candidate.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2000
                  ] as CFDictionary),
                  let encoded = UIImage(cgImage: bitmap).jpegData(compressionQuality: 0.87) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard !Task.isCancelled, candidate == item else { return }
            if meal == nil, initialDate == nil {
                let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if (access == .authorized || access == .limited),
                   let id = candidate.itemIdentifier,
                   let original = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject?.creationDate {
                    date = original
                    includesDate = true
                } else if let taken = captureDate(source) {
                    date = taken
                    includesDate = true
                }
            }
            selectedPlateID = nil
            cropSource = encoded
            originalPhoto = encoded
            photo = encoded
            showingCrop = true
        } catch {
            if !Task.isCancelled { self.error = "写真を読み込めませんでした。" }
        }
    }

    private func captureDate(_ source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            if let result = formatter.date(from: raw + offset) { return result }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }
}

struct PlacePicker: View {
    @Binding var selection: Place?
    var allowsHome = true
    var initialQuery = ""
    @Environment(\.dismiss) private var dismiss
    @Query private var meals: [Meal]
    @State private var query = ""
    @StateObject private var suggestions = PlaceSuggestions()
    @State private var resolving = false
    @State private var suggestionError = false
    @State private var results: [Place] = []
    @State private var status = ""

    private var savedPlaces: [Place] {
        var seen = Set<String>()
        return meals.compactMap(\.place).filter { $0.coordinate != nil && seen.insert($0.id).inserted }
            .filter { query.isEmpty || ($0.name + $0.address).localizedStandardContains(query) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section {
                if allowsHome { placeRow(.home) }
                if selection != nil {
                    Button("場所を外す", role: .destructive) { select(nil) }
                }
            }
            if !savedPlaces.isEmpty {
                Section("記録済みの場所") {
                    ForEach(savedPlaces) { placeRow($0) }
                }
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("検索結果") {
                    if resolving { ProgressView("場所を確認中…") }
                    if !status.isEmpty && suggestions.matches.isEmpty {
                        Text(status).foregroundStyle(.secondary)
                    }
                    ForEach(results) { placeRow($0) }
                }
            }
            if !suggestions.matches.isEmpty {
                Section("店名・施設の候補") {
                    ForEach(suggestions.matches, id: \.self) { item in
                        Button {
                            Task { await resolve(item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(item.title, systemImage: "mappin")
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(resolving)
                    }
                }
            }
        }
        .navigationTitle("場所を選ぶ")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if query.isEmpty { query = initialQuery } }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "店名・地名で検索")
        .task(id: query) {
            suggestions.update(query)
            await search(query)
        }
        .alert("場所を開けませんでした", isPresented: $suggestionError) {
            Button("閉じる", role: .cancel) {}
        }
    }

    private func placeRow(_ place: Place) -> some View {
        Button { select(place) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(place.name, systemImage: place.id == "home" ? "house" : "mappin")
                if !place.address.isEmpty {
                    Text(place.address).font(.system(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func select(_ place: Place?) {
        selection = place
        dismiss()
    }

    @MainActor private func resolve(_ completion: MKLocalSearchCompletion) async {
        guard !resolving else { return }
        resolving = true
        defer { resolving = false }
        do {
            let request = MKLocalSearch.Request(completion: completion)
            let response = try await MKLocalSearch(request: request).start()
            guard let result = response.mapItems.first else {
                suggestionError = true
                return
            }
            select(Place(result))
        } catch {
            suggestionError = true
        }
    }

    private func search(_ query: String) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []
        status = ""
        guard !term.isEmpty else { return }
        status = "検索中…"
        do {
            try await Task.sleep(for: .milliseconds(350))
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = term
            request.resultTypes = [.address, .pointOfInterest]
            let search = MKLocalSearch(request: request)
            let response = try await withTaskCancellationHandler {
                try await search.start()
            } onCancel: {
                search.cancel()
            }
            guard !Task.isCancelled else { return }
            var seen = Set<String>()
            results = response.mapItems.map(Place.init).filter { seen.insert($0.id).inserted }
            status = results.isEmpty ? "場所が見つかりませんでした" : ""
        } catch {
            if !Task.isCancelled {
                status = (error as? MKError)?.code == .placemarkNotFound
                    ? "場所が見つかりませんでした" : "検索できませんでした。通信状況を確認してください。"
            }
        }
    }
}


private final class PlaceSuggestions: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var matches: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = [.pointOfInterest, .address]
        completer.delegate = self
    }

    func update(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        completer.cancel()
        matches = []
        if !term.isEmpty { completer.queryFragment = term }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        matches = Array(completer.results.prefix(12))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        matches = []
    }
}
