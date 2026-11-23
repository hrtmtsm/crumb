import SwiftUI
import CloudKit

struct MealFolderDetail: View {
    var owned: PersonalMap?
    let zone: CKRecordZone.ID
    let meals: [Meal]
    var refreshVersion = 0
    var onChange: ((PersonalMap) -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    @State private var inviteAfterPeople = false
    @State private var showingPeople = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var draft = ""
    @State private var choosing = false
    @State private var selected: Set<UUID> = []
    @State private var remote: [Meal] = []
    @State private var share: CKShare?
    @State private var invitation: MapInvitation?
    @State private var busy = false
    @State private var error: String?

    private var database: CKDatabase {
        owned == nil ? MapCloud.container.sharedCloudDatabase : MapCloud.container.privateCloudDatabase
    }

    private var entries: [Meal] {
        let local = meals.filter { owned?.mealIDs.contains($0.id) == true }
        let ids = Set(local.map(\.id))
        let shared = remote.filter { !ids.contains($0.id) }.map { entry in
            meals.first { $0.id == entry.id } ?? entry
        }
        return (local + shared).sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingPeople = true
                } label: {
                    HStack(spacing: 8) {
                        if owned != nil { Image(systemName: "plus.circle.fill") }
                        HStack(spacing: -5) {
                            ForEach(0..<min(3, share?.participants.count ?? (owned == nil ? 0 : 1)), id: \.self) { _ in
                                Image(systemName: "person.crop.circle.fill")
                                    .padding(3).background(paper, in: Circle())
                            }
                        }
                        Text("参加者 \(share?.participants.count ?? (owned == nil ? 0 : 1))")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    if owned != nil {
                        Button("フォルダ名を編集", systemImage: "pencil") {
                            draft = owned?.title ?? ""
                            renaming = true
                        }
                        Button("フォルダを削除", systemImage: "trash", role: .destructive) { deleting = true }
                    }
                    if owned != nil || share?.currentUserParticipant?.permission == .readWrite {
                        Button("既存の料理を追加", systemImage: "plus") {
                            selected = []
                            choosing = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .accessibilityLabel("フォルダの操作")
                .disabled(busy || (owned == nil && share?.currentUserParticipant?.permission != .readWrite))
            }
            .padding(.horizontal, 22)
            ScrollView {
                if entries.isEmpty {
                    ContentUnavailableView("まだ料理がありません", systemImage: "fork.knife")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 26) {
                    ForEach(entries) { meal in
                        NavigationLink {
                            MealDetail(meal: meal, canEdit: meals.contains { $0.id == meal.id })
                        } label: {
                            AlbumTile(meal: meal)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 82)
            }
        }
        .sheet(isPresented: $showingPeople, onDismiss: {
            if inviteAfterPeople {
                inviteAfterPeople = false
                Task { await invite() }
            }
        }) {
            NavigationStack {
                List {
                    Section("参加者") {
                        if owned != nil {
                            Button("参加者を招待", systemImage: "person.badge.plus") {
                                inviteAfterPeople = true
                                showingPeople = false
                            }
                            .disabled(busy)
                        }
                        if let share {
                            ForEach(Array(share.participants.enumerated()), id: \.offset) { _, participant in
                                VStack(alignment: .leading, spacing: 3) {
                                    let name = participant.userIdentity.nameComponents.map {
                                        PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
                                    } ?? ""
                                    Text(name.isEmpty ? (participant.role == .owner ? "オーナー" : "参加者") : name)
                                    Text(participant.role == .owner ? "オーナー" :
                                         participant.acceptanceStatus == .pending ? "招待中" :
                                         participant.acceptanceStatus == .accepted ? "参加済み" : "参加状況不明")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else if owned != nil {
                            Label("あなた（オーナー）", systemImage: "person.crop.circle")
                        } else {
                            Text("参加者の情報を読み込み中").foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("参加者")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("フォルダ名を編集", isPresented: $renaming) {
            TextField("フォルダ名", text: $draft)
            Button("キャンセル", role: .cancel) {}
            Button("保存") { Task { await rename() } }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("フォルダを削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await deleteFolder() } }
        } message: {
            Text("共有している場合は参加者も開けなくなります。コレクションの料理は残ります。")
        }
        .task(id: refreshVersion) { await reload() }
        .refreshable { await reload() }
        .sheet(item: $invitation, onDismiss: { Task { await reload() } }) { item in
            MapInviteSheet(invitation: item) { error = $0.localizedDescription }
        }
        .sheet(isPresented: $choosing) {
            NavigationStack {
                List(meals.filter { meal in !entries.contains { $0.id == meal.id } }) { meal in
                    Button {
                        if selected.contains(meal.id) { selected.remove(meal.id) }
                        else { selected.insert(meal.id) }
                    } label: {
                        HStack {
                            Text(meal.title)
                            Spacer()
                            if selected.contains(meal.id) { Image(systemName: "checkmark") }
                        }
                    }
                }
                .navigationTitle("追加する料理")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { choosing = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("追加") {
                            let ids = selected
                            choosing = false
                            Task { await add(ids) }
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .alert("フォルダを更新できませんでした", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("閉じる", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func rename() async {
        guard var folder = owned else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            if MapCloud.enabled, let share = try await MapCloud.existingShare(in: zone, database: database) {
                let root = try await database.record(for: CKRecord.ID(recordName: "map", zoneID: zone))
                root["title"] = name
                share[CKShare.SystemFieldKey.title] = name
                let result = try await database.modifyRecords(saving: [root, share], deleting: [], atomically: true)
                for outcome in result.saveResults.values { _ = try outcome.get() }
            }
            folder.title = name
            onChange?(folder)
        } catch { self.error = error.localizedDescription }
    }

    private func deleteFolder() async {
        busy = true
        defer { busy = false }
        do {
            if MapCloud.enabled, try await MapCloud.existingShare(in: zone, database: database) != nil {
                _ = try await database.deleteRecordZone(withID: zone)
            }
            onDelete?()
        } catch { self.error = error.localizedDescription }
    }

    private func reload() async {
        guard MapCloud.enabled else { return }
        do {
            share = try await MapCloud.existingShare(in: zone, database: database)
            if share != nil { remote = try await MapCloud.meals(in: zone, database: database) }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func invite() async {
        guard let owned else { return }
        guard MapCloud.enabled else {
            error = "招待は iCloud 対応のビルドで利用できます。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let sheet = try await MapCloud.invite(owned, meals: meals.filter { owned.mealIDs.contains($0.id) }, folder: true)
            share = sheet
            invitation = MapInvitation(share: sheet)
        } catch { self.error = error.localizedDescription }
    }

    private func add(_ ids: Set<UUID>) async {
        busy = true
        defer { busy = false }
        do {
            if MapCloud.enabled {
                share = try await MapCloud.existingShare(in: zone, database: database)
                if share != nil {
                    try await MapCloud.add(meals.filter { ids.contains($0.id) }, to: zone, database: database)
                } else if owned == nil {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            if var folder = owned {
                folder.mealIDs.formUnion(ids)
                onChange?(folder)
            }
            await reload()
        } catch { self.error = error.localizedDescription }
    }
}
