import SwiftUI
import SwiftData
import PhotosUI

struct ProfileAvatar: View {
    @AppStorage("profileAvatar") private var photo = Data()
    var size: CGFloat
    var body: some View { AvatarImage(data: photo, size: size) }
}

private struct AvatarImage: View {
    let data: Data
    let size: CGFloat
    var body: some View {
        Group {
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image("CrumbAvatar").renderingMode(.original).resizable().scaledToFit().padding(size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .background(.white, in: .circle).clipShape(.circle)
        .overlay(Circle().strokeBorder(fieldBorder, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct ProfileView: View {
    @Query private var meals: [Meal]
    @AppStorage("profileName") private var name = ""
    @AppStorage("menuBooks") private var storedBooks = "[]"
    @AppStorage("selectedMenuBook") private var selectedBookID = MenuBook.defaultID
    @AppStorage("appLanguage", store: .standard) private var language = AppLanguage.defaultCode
    @AppStorage("hapticsEnabled", store: .standard) private var hapticsEnabled = true
    @State private var editing = false
    @State private var choosingLanguage = false
    @State private var showingOnboarding = false
    private var books: [MenuBook] { MenuBook.decode(storedBooks) }
    private var recipeCount: Int { meals.filter { $0.wantToVisit != true }.count }
    private var languageName: String {
        switch language { case "ja": return "日本語"; case "ko": return "한국어"; default: return "English" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button { CrumbHaptics.tap(); editing = true } label: {
                    HStack(spacing: 18) {
                        ProfileAvatar(size: 84)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil")
                                    .font(.caption.weight(.semibold))
                                    .padding(8).background(paper, in: .circle)
                            }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name.isEmpty ? AppLanguage.text("名前を設定") : name)
                                .font(.custom("Nunito-SemiBold", size: 25, relativeTo: .title2))
                            Text("\(books.count)ブック・\(recipeCount)レシピ")
                                .font(.subheadline).foregroundStyle(secondaryInk)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.subheadline).foregroundStyle(secondaryInk)
                    }.padding(.vertical, 12)
                }.buttonStyle(.plain).accessibilityLabel("プロフィールを編集")

                VStack(spacing: 0) {
                    NavigationLink(value: AlbumRoute.books) {
                        profileRow("メニューブックを管理", icon: "book", value: books.first { $0.id == selectedBookID }?.name ?? AppLanguage.text("My Menu"))
                    }.buttonStyle(.plain)
                    Divider().padding(.leading, 54)
                    Button { CrumbHaptics.tap(); choosingLanguage = true } label: {
                        profileRow("言語", icon: "globe", value: languageName)
                    }.buttonStyle(.plain)
                    Divider().padding(.leading, 54)
                    Toggle(isOn: $hapticsEnabled) {
                        HStack(spacing: 14) {
                            Image(systemName: "hand.tap").font(.title3).frame(width: 26)
                            Text("操作時の振動").font(.system(.body).weight(.semibold))
                        }
                    }
                    .tint(ink).padding(18).frame(minHeight: 64)
                }
                .background(ink.opacity(0.035), in: .rect(cornerRadius: 22))
                Button { CrumbHaptics.tap(); showingOnboarding = true } label: {
                    profileRow("アプリの使い方", icon: "questionmark.circle", value: "")
                }
                .buttonStyle(.plain)
                .background(ink.opacity(0.035), in: .rect(cornerRadius: 22))
                PlusSettingsSection()
                AccountSettingsSection()
            }
            .padding(22)
        }
        .foregroundStyle(ink).background(paper.ignoresSafeArea())
        .navigationTitle("プロフィール").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $editing) { ProfileEditor() }
        .sheet(isPresented: $choosingLanguage) { LanguageSettings() }
        .fullScreenCover(isPresented: $showingOnboarding) {
            CrumbOnboarding { showingOnboarding = false }
        }
    }

    private func profileRow(_ title: LocalizedStringKey, icon: String, value: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 26)
            Text(title).font(.system(.body).weight(.semibold))
            Spacer(minLength: 8)
            Text(verbatim: value).font(.subheadline).foregroundStyle(secondaryInk).lineLimit(1)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(secondaryInk)
        }.padding(18).frame(minHeight: 64).contentShape(Rectangle())
    }
}

private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("profileName") private var savedName = ""
    @AppStorage("profileAvatar") private var savedPhoto = Data()
    @State private var name = ""
    @State private var photo = Data()
    @State private var item: PhotosPickerItem?
    @State private var loading = false
    @State private var failed = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            AvatarImage(data: photo, size: 96)
                            PhotosPicker("写真を変更", selection: $item, matching: .images).hapticActivation()
                            if loading { ProgressView() }
                            if !photo.isEmpty {
                                Button("デフォルトの顔に戻す") { CrumbHaptics.tap(); photo = Data(); item = nil }
                            }
                        }
                        Spacer()
                    }.padding(.vertical, 12)
                }
                Section("名前") { TextField("名前", text: $name).textContentType(.nickname) }
            }
            .navigationTitle("プロフィールを編集").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { CrumbHaptics.tap(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { CrumbHaptics.tap();
                        savedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        savedPhoto = photo
                        NotificationCenter.default.post(name: .crumbLibraryChanged, object: nil)
                        dismiss()
                    }.disabled(loading)
                }
            }
            .onAppear { name = savedName; photo = savedPhoto }
            .task(id: item) {
                guard let item else { return }
                loading = true
                defer { loading = false }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { failed = true; return }
                    try Task.checkCancellation()
                    let side = min(image.size.width, image.size.height)
                    guard side > 0 else { failed = true; return }
                    let output = CGSize(width: 512, height: 512)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let rendered = UIGraphicsImageRenderer(size: output, format: format).image { _ in
                        let scale = 512 / side
                        image.draw(in: CGRect(x: (512 - image.size.width * scale) / 2,
                                              y: (512 - image.size.height * scale) / 2,
                                              width: image.size.width * scale, height: image.size.height * scale))
                    }
                    guard let encoded = rendered.jpegData(compressionQuality: 0.85) else { failed = true; return }
                    photo = encoded
                } catch { if !Task.isCancelled { failed = true } }
            }
            .alert("写真を読み込めませんでした", isPresented: $failed) { Button("閉じる", role: .cancel) { CrumbHaptics.tap() } }
        }
    }
}
