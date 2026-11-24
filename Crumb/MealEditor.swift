import SwiftUI
import PhotosUI
import Photos
import SwiftData
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
    @State private var photoFraming: String?
    @State private var date: Date
    @State private var includesDate: Bool
    @State private var structured: MealRecipe
    @State private var includesRecipe: Bool
    @State private var showRecipe = false
    @State private var recipeSection = 0
    @State private var name: String
    @State private var note: String
    @State private var recipe: String
    @State private var recipeURL: String
    @State private var place: Place?
    @State private var loading = false
    @State private var error: String?
    @State private var syncing = false
    @Query private var allMeals: [Meal]
    @State private var categories: [String]
    @State private var menuBookID: String
    @AppStorage("menuBooks") private var storedBooks = "[]"
    @State private var newCategory = ""
    @State private var addingCategory = false
    @AppStorage("recipeCategories") private var storedCategories = "[]"


    init(meal: Meal?, initialDate: Date? = nil, initialPhoto: Data? = nil, initialBookID: String = MenuBook.defaultID, onSaved: ((Meal) -> Void)? = nil) {
        self.meal = meal
        self.initialDate = initialDate
        self.onSaved = onSaved
        _photo = State(initialValue: meal?.photo ?? initialPhoto)
        _originalPhoto = State(initialValue: meal?.originalPhoto ?? meal?.photo ?? initialPhoto)
        _selectedPlateID = State(initialValue: meal?.selectedPlateID)
        _photoFraming = State(initialValue: meal?.photoFraming)
        _date = State(initialValue: meal?.date ?? initialDate ?? .now)
        _includesDate = State(initialValue: meal == nil || meal?.recordedDate != nil || initialDate != nil)
        let existingRecipe = MealRecipe(contents: meal?.structuredRecipe)
        _structured = State(initialValue: existingRecipe)
        _includesRecipe = State(initialValue: true)
        _categories = State(initialValue: meal?.categories ?? [])
        _menuBookID = State(initialValue: meal?.menuBookID ?? initialBookID)
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
                    editorSection("ひとこと") {
                        TextField("メモを追加（任意）", text: $note, axis: .vertical)
                    }
                    editorSection("メニューブック") {
                        Picker("保存先", selection: $menuBookID) {
                            ForEach(MenuBook.decode(storedBooks)) { book in
                                Text(verbatim: book.name).tag(book.id)
                            }
                        }.pickerStyle(.menu)
                    }
                    categoryEditor
                    if let originalPhoto {
                        PhotoPlating(original: originalPhoto, photo: $photo, working: $styling, plateID: $selectedPlateID, framing: $photoFraming)
                            .id(originalPhoto)
                            .disabled(loading || syncing)
                    }
                    editorSection("日付") {
                        Toggle("日付を記録", isOn: $includesDate)
                        if includesDate {
                            DatePicker("食事の日", selection: $date, displayedComponents: .date)
                        }
                    }
                    editorSection("レシピ") {
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
            .navigationTitle(LocalizedStringKey(meal == nil ? "レシピを追加" : "レシピを編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("キャンセル")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("レシピを保存", systemImage: "checkmark", action: save)
                        .font(.system(.body).weight(.semibold))
                    .disabled(photo == nil || loading || syncing || styling)
                    .accessibilityLabel("レシピを保存")
                }
            }
            .navigationDestination(isPresented: $showRecipe) {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(name.isEmpty ? AppLanguage.text("料理名未設定") : name).font(.title2.bold())
                        servingsPicker
                        Picker("レシピの編集", selection: $recipeSection) {
                            Text("材料").tag(0)
                            Text("手順").tag(1)
                        }.pickerStyle(.segmented)
                    }.padding(.horizontal, 22).padding(.top, 12)
                    ZStack {
                        recipeEditorPage(ingredients: true)
                            .opacity(recipeSection == 0 ? 1 : 0)
                            .allowsHitTesting(recipeSection == 0).accessibilityHidden(recipeSection != 0)
                        recipeEditorPage(ingredients: false)
                            .opacity(recipeSection == 1 ? 1 : 0)
                            .allowsHitTesting(recipeSection == 1).accessibilityHidden(recipeSection != 1)
                    }
                }
                .onAppear {
                    if structured.steps.isEmpty { structured.steps.append("") }
                }
                .onChange(of: recipeSection) { _, _ in hideKeyboard() }
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
                if let data = originalPhoto ?? cropSource {
                    if let frame = PhotoFrame.decode(photoFraming),
                       ["丸", "花形", "ひし形", "波形", "六角形", "角丸", "楕円"].contains(frame.shape) {
                        ShapeCropSource(original: data, frame: frame) { updated, result in
                            photoFraming = updated.encoded
                            photo = result
                            styling = false
                        }
                    } else if let image = UIImage(data: data) {
                        MealPhotoCropper(image: image) { cropped in
                            selectedPlateID = nil
                            photoFraming = nil
                            cropSource = nil
                            originalPhoto = cropped
                            photo = cropped
                            styling = false
                        }
                    }
                }
            }
            .task(id: item) { await loadPhoto(item) }
            .alert(AppLanguage.text(error ?? ""), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("閉じる", role: .cancel) {}
            }
        }
    }

    private var availableCategories: [String] {
        RecipeCategories.normalized(RecipeCategories.decode(storedCategories) + allMeals.filter { $0.wantToVisit != true }.flatMap(\.categories) + categories)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var categoryEditor: some View {
        editorSection("カテゴリ") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    editorCategoryChip(nil)
                    Button {
                        newCategory = ""
                        addingCategory = true
                    } label: {
                        Image(systemName: "plus").font(.subheadline.weight(.medium))
                            .frame(width: 44, height: 40)
                            .background(ink.opacity(0.06), in: .capsule)
                    }.buttonStyle(.plain).accessibilityLabel("カテゴリを追加")
                    ForEach(availableCategories, id: \.self) { category in
                        editorCategoryChip(category)
                    }
                }
            }
        }
        .alert("カテゴリを追加", isPresented: $addingCategory) {
            TextField("カテゴリ名", text: $newCategory)
            Button("追加", action: addCategory)
                .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("キャンセル", role: .cancel) { newCategory = "" }
        }
    }

    private func editorCategoryChip(_ category: String?) -> some View {
        let selected = category.map { name in categories.contains { RecipeCategories.matches($0, name) } } ?? categories.isEmpty
        return Button {
            categories = category.map { [$0] } ?? []
        } label: {
            Text(verbatim: category ?? "All")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(selected ? .white : ink)
                .background(selected ? ink : ink.opacity(0.06), in: .capsule)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func addCategory() {
        let clean = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let existing = availableCategories.first { RecipeCategories.matches($0, clean) } ?? clean
        categories = [existing]
        storedCategories = RecipeCategories.encode(availableCategories + [existing])
        newCategory = ""
    }

    private var servingsPicker: some View {
        Stepper("\(structured.servings)人前", value: Binding(
            get: { structured.servings }, set: { structured.changeServings(to: $0) }
        ), in: 1...99)
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func recipeEditorPage(ingredients: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MealRecipeEditor(recipe: $structured, showsIngredients: ingredients, showsSteps: !ingredients)
                if !ingredients {
                    if !(meal?.recipe.isEmpty ?? true) {
                        TextField("レシピメモ", text: $recipe, axis: .vertical).lineLimit(3...10)
                    }
                }
            }.padding(22)
        }.scrollDismissesKeyboard(.interactively)
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
        let record = meal ?? Meal(photo: photo, name: name, date: date, place: nil)
        if meal == nil { context.insert(record) }
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.photo != photo { record.photo = photo }
        record.selectedPlateID = selectedPlateID
        record.photoFraming = photoFraming
        record.originalPhoto = originalPhoto == photo ? nil : originalPhoto
        record.date = date
        record.dateOmitted = !includesDate
        record.note = note
        record.categories = categories
        record.menuBookID = menuBookID == MenuBook.defaultID ? nil : menuBookID
        let cleanURL = includesRecipe ? recipeURL.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let recipeNote = includesRecipe ? recipe : ""
        var cleanRecipe = structured
        cleanRecipe.steps = cleanRecipe.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for index in cleanRecipe.steps.indices.reversed() where cleanRecipe.steps[index].isEmpty {
            cleanRecipe.removeStep(at: index)
        }
        let contents = includesRecipe ? cleanRecipe.contents : nil
        if record.recipe != recipeNote || record.recipeURL != cleanURL ||
            MealRecipe(contents: record.structuredRecipe).contents != contents {
            record.structuredRecipe = contents
            record.recipe = recipeNote
            record.recipeURL = cleanURL
            record.recipeUpdatedAt = .now
        }
        do {
            try context.save()
            onSaved?(record)
            dismiss()
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
                        photoFraming = nil
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
