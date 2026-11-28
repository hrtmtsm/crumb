import SwiftUI
import PhotosUI
import Photos
import SwiftData
import ImageIO

enum MealEditorLayout {
    static let sectionSpacing: CGFloat = 24
}

struct MealEditor: View {
    @EnvironmentObject private var plus: PlusStore
    @EnvironmentObject private var cloud: CloudLibrary
    @EnvironmentObject private var account: AccountStore
    private func editable(_ id: String) -> Bool {
        guard let book = MenuBook.decode(storedBooks).first(where: { $0.id == id }) else { return false }
        return PlanPolicy.canEdit(book: cloud.resolved(book), viewer: account.session?.userID, plus: plus.hasPlus)
    }
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
    @State private var showRecipe = false
    @State private var recipeSection = 0
    @State private var captureMode: RecipeCapture.Mode?
    @State private var pendingImport: RecipeDraft?
    @State private var confirmingImport = false
    @State private var useAICover = false
    private let draft: RecipeDraft?
    @State private var styling = false
    @State private var selectedPlateID: String?
    @State private var photoFraming: String?
    @State private var date: Date
    @State private var includesDate: Bool
    @State private var structured: MealRecipe
    @State private var includesRecipe: Bool
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
    @FocusState private var editorFocus: RecipeEditorField?
    @State private var keyboardVisible = false
    @State private var focusScrollRevision = 0
    private var categoryFocused: Bool { editorFocus == .category }
    @AppStorage("recipeCategories") private var storedCategories = "[]"


    init(meal: Meal?, initialDate: Date? = nil, initialPhoto: Data? = nil, initialBookID: String = MenuBook.defaultID, draft: RecipeDraft? = nil, onSaved: ((Meal) -> Void)? = nil) {
        self.meal = meal
        self.draft = draft
        self.initialDate = initialDate
        self.onSaved = onSaved
        _photo = State(initialValue: meal?.photo ?? initialPhoto)
        _originalPhoto = State(initialValue: meal?.originalPhoto ?? meal?.photo ?? initialPhoto)
        _selectedPlateID = State(initialValue: meal?.selectedPlateID)
        _photoFraming = State(initialValue: meal?.photoFraming)
        _date = State(initialValue: meal?.date ?? initialDate ?? .now)
        _includesDate = State(initialValue: meal == nil || meal?.recordedDate != nil || initialDate != nil)
        let existingRecipe = draft?.recipe ?? MealRecipe(contents: meal?.structuredRecipe)
        _structured = State(initialValue: existingRecipe)
        _includesRecipe = State(initialValue: true)
        _categories = State(initialValue: meal?.categories ?? [])
        _menuBookID = State(initialValue: meal?.menuBookID ?? initialBookID)
        _name = State(initialValue: draft?.title ?? meal?.name ?? "")
        _note = State(initialValue: draft?.notes ?? meal?.note ?? "")
        _recipe = State(initialValue: meal?.recipe ?? "")
        _recipeURL = State(initialValue: draft?.source ?? meal?.recipeURL ?? "")
        _place = State(initialValue: meal?.place)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { editorScroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: MealEditorLayout.sectionSpacing) {
                        photoHero
                        if originalPhoto != nil {
                            Button {
                                CrumbHaptics.tap(); showingCrop = true
                            } label: {
                                Label("トリミング", systemImage: "crop")
                                    .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                            }.frame(maxWidth: .infinity)
                                .disabled(loading || syncing || styling)
                        }
                        if let preview = draft?.previewData, let image = UIImage(data: preview) {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(uiImage: image).resizable().scaledToFit().frame(height: 160).clipShape(.rect(cornerRadius: 14))
                                Text("AI preview").font(.caption).foregroundStyle(secondaryInk)
                                Toggle("Use as cover", isOn: $useAICover)
                                    .onChange(of: useAICover) { _, use in
                                        photo = use ? preview : initialDraftPhoto
                                        originalPhoto = photo
                                    }
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("料理名").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            TextField("料理名（任意）", text: $name)
                                .focused($editorFocus, equals: .dishName)
                                .id(RecipeEditorField.dishName)
                                .padding(15)
                                .background(ink.opacity(0.025), in: .rect(cornerRadius: 12))
                                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ink.opacity(0.13)) }
                        }
                        editorSection("ひとこと") {
                            TextField("メモを追加（任意）", text: $note, axis: .vertical)
                                .lineLimit(1...5).focused($editorFocus, equals: .note)
                                .id(RecipeEditorField.note)
                        }
                        categoryEditor.id(RecipeEditorField.category)
                        if let originalPhoto {
                            PhotoPlating(original: originalPhoto, photo: $photo, working: $styling, plateID: $selectedPlateID, framing: $photoFraming)
                                .id(originalPhoto)
                                .disabled(loading || syncing)
                        }
                        editorSection("日付") {
                            HStack(spacing: 10) {
                                Text("日付を記録")
                                if includesDate { DatePicker("日付", selection: $date, displayedComponents: .date).labelsHidden().datePickerStyle(.compact).fixedSize() }
                                Spacer(minLength: 0)
                                Toggle("日付を記録", isOn: $includesDate).labelsHidden().fixedSize()
                            }
                        }
                        editorSection("レシピ") {
                            Button { CrumbHaptics.tap(); showRecipe = true } label: {
                                HStack {
                                    Text("材料と作り方を編集")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                            }.buttonStyle(.plain)
                        }
                        if !recipeURL.isEmpty {
                            editorSection("Source") {
                                TextField("https://", text: $recipeURL).keyboardType(.URL).textInputAutocapitalization(.never)
                                    .focused($editorFocus, equals: .source)
                                    .id(RecipeEditorField.source)
                            }
                        }
                        if let origin = draft?.originRecipeID ?? structured.originRecipeID,
                           let original = allMeals.first(where: { $0.id == origin }) {
                            Text("Adapted from \(original.title)").font(.footnote).foregroundStyle(secondaryInk)
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 18)

                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: editorFocus) { _, _ in focusScrollRevision += 1 }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                    updateKeyboard(notification)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidChangeFrameNotification)) { notification in
                    updateKeyboard(notification)
                }
                .task(id: focusScrollRevision) {
                    guard let target = editorFocus else { return }
                    switch target { case .name, .amount, .unit, .step: return; default: break }
                    // A keyboard resize and a row insertion can occur in the same update.
                    // Scroll after layout, and repeat when the final keyboard frame arrives.
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                    guard !Task.isCancelled, editorFocus == target else { return }
                    editorScroll.scrollTo(target, anchor: .center)
                }
            }

            .background(paper.ignoresSafeArea())
            .navigationTitle(LocalizedStringKey(meal == nil ? "レシピを追加" : "レシピを編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { CrumbHaptics.tap(); dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("キャンセル")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft?.originRecipeID != nil ? "Save as new recipe" : "Save recipe", systemImage: "checkmark", action: CrumbHaptics.action(save))
                        .font(.system(.body).weight(.semibold))
                    .disabled(loading || syncing || styling)
                    .accessibilityLabel(draft?.originRecipeID != nil ? "Save as new recipe" : "Save recipe")
                    .keyboardShortcut("s", modifiers: .command)
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
            .sheet(item: $captureMode, onDismiss: {
                if pendingImport != nil {
                    if structured.cleaned.isEmpty && name.isEmpty && note.isEmpty && recipe.isEmpty { applyImport(replacing: true) }
                    else { confirmingImport = true }
                }
            }) { mode in
                RecipeCapture(mode: mode, initialURL: mode == .link ? recipeURL : "") { imported in
                    pendingImport = imported
                }
            }
            .confirmationDialog("Apply imported recipe?", isPresented: $confirmingImport, titleVisibility: .visible) {
                Button("Replace recipe fields") { applyImport(replacing: true) }
                Button("Add to existing recipe") { applyImport(replacing: false) }
                Button("Cancel", role: .cancel) { pendingImport = nil }
            } message: { Text("Your current recipe stays unchanged until you choose. Photos and styling are kept.") }
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
            .task {
                if draft?.source != nil && draft?.recipe.isEmpty == true { captureMode = .link }
            }
            .alert(AppLanguage.text(error ?? ""), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("閉じる", role: .cancel) { CrumbHaptics.tap() }
            }
        }
    }

    private func updateKeyboard(_ notification: Notification) {
        guard let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        keyboardVisible = frame.height > 0 && frame.minY < UIScreen.main.bounds.height
        if keyboardVisible, editorFocus != nil { focusScrollRevision += 1 }
    }

    private var initialDraftPhoto: Data? { meal?.photo }

    private func applyImport(replacing: Bool) {
        guard let imported = pendingImport else { return }
        if replacing {
            structured = imported.recipe
            if !imported.title.isEmpty { name = imported.title }
            if !imported.notes.isEmpty { note = imported.notes }
        } else {
            let wasEmpty = structured.cleaned.isEmpty
            structured = structured.cleaned
            if wasEmpty { structured.servings = imported.recipe.servings; structured.servingsKnown = imported.recipe.servingsKnown }
            structured.ingredients.append(contentsOf: imported.recipe.ingredients)
            let oldCount = structured.steps.count
            structured.steps.append(contentsOf: imported.recipe.steps)
            var refs = structured.stepIngredients ?? []
            while refs.count < oldCount { refs.append([]) }
            refs.append(contentsOf: imported.recipe.stepIngredients ?? Array(repeating: [], count: imported.recipe.steps.count))
            structured.stepIngredients = refs
            if name.isEmpty { name = imported.title }
            note = [note, imported.notes].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        if let source = imported.source { recipeURL = source }
        pendingImport = nil
    }
    private var availableCategories: [String] {
        RecipeCategories.normalized(RecipeCategories.decode(storedCategories) + allMeals.filter { $0.wantToVisit != true }.flatMap(\.categories) + categories)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var categoryEditor: some View {
        editorSection("カテゴリ", framed: false) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        editorCategoryChip(nil)
                        ForEach(availableCategories, id: \.self) { category in
                            editorCategoryChip(category)
                        }
                        Group {
                            if addingCategory {
                                HStack(spacing: 0) {
                                    TextField("カテゴリ名", text: $newCategory)
                                        .font(.subheadline)
                                        .frame(width: 120)
                                        .padding(.leading, 14)
                                        .focused($editorFocus, equals: .category)
                                        .submitLabel(.done)
                                        .onSubmit(addCategory)
                                        .accessibilityLabel("カテゴリ名")
                                    Button(action: CrumbHaptics.action(addCategory)) {
                                        Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain).accessibilityLabel("カテゴリを追加")
                                    .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    Button(action: CrumbHaptics.action(cancelCategory)) {
                                        Image(systemName: "xmark").font(.caption.weight(.medium))
                                            .foregroundStyle(secondaryInk).frame(width: 44, height: 44)
                                    }.buttonStyle(.plain).accessibilityLabel("キャンセル")
                                }
                                .background(ink.opacity(0.06), in: .capsule)
                                .task { await Task.yield(); editorFocus = .category }
                            } else {
                                Button { CrumbHaptics.tap();
                                    newCategory = ""
                                    addingCategory = true
                                } label: {
                                    Image(systemName: "plus").font(.subheadline.weight(.medium))
                                        .frame(width: 44, height: 44)
                                        .background(ink.opacity(0.06), in: .capsule)
                                }.buttonStyle(.plain).accessibilityLabel("カテゴリを追加")
                            }
                        }.id("category-composer")
                    }
                }
                .onChange(of: addingCategory) { _, active in
                    if active { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("category-composer", anchor: .trailing) } }
                }
                .onChange(of: availableCategories) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("category-composer", anchor: .trailing) }
                }
            }
        }
    }

    private func cancelCategory() {
        if editorFocus == .category { editorFocus = nil }
        addingCategory = false
        newCategory = ""
    }

    private func editorCategoryChip(_ category: String?) -> some View {
        let selected = category.map { name in categories.contains { RecipeCategories.matches($0, name) } } ?? categories.isEmpty
        return Button { CrumbHaptics.tap();
            categories = category.map { [$0] } ?? []
            cancelCategory()
        } label: {
            Text(verbatim: category ?? AppLanguage.text("All"))
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(selected ? .white : ink)
                .background(selected ? ink : ink.opacity(0.06), in: .capsule)
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
        .categoryActions(category, enabled: editable(menuBookID), canEdit: editable) { old, replacement in
            categories = RecipeCategories.replacing(old, with: replacement, in: categories)
        }
    }

    private func addCategory() {
        let clean = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let existing = availableCategories.first { RecipeCategories.matches($0, clean) } ?? clean
        categories = [existing]
        storedCategories = RecipeCategories.encode(availableCategories + [existing])
        cancelCategory()
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

    private func editorSection<Content: View>(_ title: LocalizedStringKey, framed: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(framed ? 14 : 0)
                .background(framed ? Color.white : Color.clear, in: .rect(cornerRadius: 12))
                .overlay {
                    if framed { RoundedRectangle(cornerRadius: 12).strokeBorder(ink.opacity(0.10)) }
                }
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
            }.hapticActivation()
            .disabled(loading || syncing || styling)
            .accessibilityLabel(Text(LocalizedStringKey(photo == nil ? "写真を選ぶ" : "写真を変更")))
        }
        .frame(maxWidth: .infinity)
    }

    private func save() {
        guard editable(menuBookID), meal.map({ editable($0.menuBookID ?? MenuBook.defaultID) }) ?? true else {
            error = "この操作にはブック所有者の有効なPlusが必要です。"; return
        }
        guard !syncing, !styling else { return }
        guard !structured.ingredients.contains(where: { $0.rawAmount?.isEmpty == false && RecipeQuantity.parse($0.rawAmount!) == nil }) else {
            error = "Enter a valid amount or fraction."; return
        }
        guard let photo = photo ?? UIImage(named: "CrumbAvatar")?.pngData() else { return }
        if addingCategory && !newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addCategory() }
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
        for ingredient in cleanRecipe.ingredients where ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanRecipe.removeIngredient(ingredient.id)
        }
        cleanRecipe.steps = cleanRecipe.steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for index in cleanRecipe.steps.indices.reversed() where cleanRecipe.steps[index].isEmpty {
            cleanRecipe.removeStep(at: index)
        }
        cleanRecipe.originRecipeID = draft?.originRecipeID ?? cleanRecipe.originRecipeID
        cleanRecipe.coverIsAI = useAICover || (draft == nil && cleanRecipe.coverIsAI == true && self.photo == meal?.photo)
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
            NotificationCenter.default.post(name: .crumbLibraryChanged, object: nil)
            CrumbHaptics.success()
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
