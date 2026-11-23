import SwiftUI
import PhotosUI
import AVKit
import CloudKit

struct WantedPlaceDetail: View {
    let pin: Meal
    let canEdit: Bool
    var sharedScope: SharedVisits?
    let save: () async throws -> Void
    @State private var sharedMedia: [VisitMemory] = []
    @State private var shareWithMembers = false
    @State private var media: [VisitMemory] = []
    @State private var selection: PhotosPickerItem?
    @State private var visitDate = Date.now
    @State private var adding = false
    @State private var showing: VisitMemory?
    @State private var failed = false
    @State private var updating = false

    private var allMedia: [VisitMemory] { (media + sharedMedia).sorted { $0.date < $1.date } }

    var body: some View {
        List {
            Section {
                Text(pin.title).font(.title2.bold())
                if let address = pin.placeAddress, !address.isEmpty { Text(address).foregroundStyle(.secondary) }
                if let author = pin.addedBy, !author.isEmpty { Label(author, systemImage: "person") }
                if !pin.note.isEmpty { Text(pin.note) }
                ForEach(Array(pin.instagramLinks.enumerated()), id: \.offset) { index, url in
                    Link("Instagramの投稿 \(index + 1)", destination: url)
                }
                if canEdit {
                    Button(pin.visited == true ? "行きたいに戻す" : "行ったにする") {
                        Task {
                            updating = true
                            let previous = pin.visited
                            pin.visited = previous != true
                            do { try await save() }
                            catch { pin.visited = previous; failed = true }
                            updating = false
                        }
                    }
                    .disabled(updating)
                } else {
                    Text(pin.visited == true ? "行った" : "行きたい")
                }
            }
            Section("思い出") {
                ForEach(allMedia) { memory in
                    Button {
                        showing = memory
                    } label: {
                        Label(memory.date.formatted(date: .abbreviated, time: .omitted),
                              systemImage: memory.video ? "video" : "photo")
                        Text(memory.shared == true ? "マップのメンバー" : "自分だけ").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if pin.visited == true {
                    Button("思い出を追加", systemImage: "plus") { adding = true }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            media = VisitMemory.load(pin.id)
            if let sharedScope {
                do { sharedMedia = try await sharedScope.load(pin: pin.id) }
                catch { if !Task.isCancelled { failed = true } }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    DatePicker("訪問日", selection: $visitDate, displayedComponents: .date)
                    Picker("公開範囲", selection: $shareWithMembers) {
                        Text("自分だけ").tag(false)
                        if sharedScope?.canUpload == true { Text("このマップのメンバー").tag(true) }
                    }
                    PhotosPicker("写真・動画を選ぶ", selection: $selection, matching: .any(of: [.images, .videos]))
                }
                .navigationTitle("訪問の思い出")
                .toolbar { Button("閉じる") { adding = false } }
            }
            .task(id: selection) {
                guard let selection else { return }
                do {
                    guard let bytes = try await selection.loadTransferable(type: Data.self),
                          bytes.count <= 30_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    let video = selection.supportedContentTypes.contains { $0.conforms(to: .movie) }
                    var memory = VisitMemory(date: visitDate, video: video)
                    if shareWithMembers, let sharedScope {
                        memory.shared = true
                        try await sharedScope.upload(memory, bytes: bytes, pin: pin.id)
                        sharedMedia = try await sharedScope.load(pin: pin.id)
                    } else {
                        try memory.store(bytes, pin: pin.id, existing: media)
                        media.append(memory)
                    }
                    adding = false
                } catch { if !Task.isCancelled { failed = true; adding = false } }
                self.selection = nil
            }
        }
        .fullScreenCover(item: $showing) { memory in
            VisitStories(memories: allMedia, pin: pin.id, index: allMedia.firstIndex { $0.id == memory.id } ?? 0)
        }
        .alert("変更を保存できませんでした", isPresented: $failed) {
            Button("閉じる", role: .cancel) {}
        }
    }
}

struct VisitMemory: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var video: Bool
    var shared: Bool?

    static func directory(_ pin: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("PrivateVisits/\(pin.uuidString)", isDirectory: true)
    }

    func file(_ pin: UUID) -> URL {
        let directory = shared == true ? URL.cachesDirectory.appendingPathComponent("SharedVisits", isDirectory: true) : Self.directory(pin)
        return directory.appendingPathComponent(id.uuidString).appendingPathExtension(video ? "mov" : "image")
    }

    static func load(_ pin: UUID) -> [Self] {
        guard let data = try? Data(contentsOf: directory(pin).appendingPathComponent("index.json")) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    func store(_ data: Data, pin: UUID, existing: [Self]) throws {
        let directory = Self.directory(pin)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(pin), options: .atomic)
        do {
            try JSONEncoder().encode(existing + [self]).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: file(pin))
            throw error
        }
    }
}

private struct VisitStories: View {
    let memories: [VisitMemory]
    let pin: UUID
    @State var index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        let memory = memories[index]
        ZStack {
            Color.black.ignoresSafeArea()
            if memory.video, let player {
                VideoPlayer(player: player)
            } else if let image = UIImage(contentsOfFile: memory.file(pin).path) {
                Image(uiImage: image).resizable().scaledToFit()
            }
            VStack {
                HStack {
                    Text("\(index + 1) / \(memories.count)")
                    Spacer()
                    Button("閉じる", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                .padding()
                HStack {
                    storyTap("前へ") { index = max(0, index - 1) }
                    storyTap("次へ") { if index + 1 < memories.count { index += 1 } else { dismiss() } }
                }
            }
            .foregroundStyle(.white)
        }
        .task(id: memory.id) {
            player?.pause()
            player = memory.video ? AVPlayer(url: memory.file(pin)) : nil
            player?.play()
        }
        .onDisappear { player?.pause() }
    }

    private func storyTap(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}


struct SharedVisits {
    let zone: CKRecordZone.ID
    let database: CKDatabase
    let canUpload: Bool

    func upload(_ memory: VisitMemory, bytes: Data, pin: UUID) async throws {
        guard canUpload, let share = try await MapCloud.existingShare(in: zone, database: database),
              share.publicPermission == .none else { throw CocoaError(.fileWriteNoPermission) }
        let parent = CKRecord.ID(recordName: pin.uuidString, zoneID: zone)
        _ = try await database.record(for: parent)
        let record = CKRecord(recordType: "CrumbVisitMemory",
                              recordID: CKRecord.ID(recordName: memory.id.uuidString, zoneID: zone))
        record.setParent(parent)
        record["pin"] = pin.uuidString
        record["visitDate"] = memory.date
        record["isVideo"] = memory.video ? 1 : 0
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(memory.id.uuidString)
        try bytes.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        record["media"] = CKAsset(fileURL: file)
        _ = try await database.save(record)
    }

    func load(pin: UUID) async throws -> [VisitMemory] {
        guard let share = try await MapCloud.existingShare(in: zone, database: database),
              share.publicPermission == .none else { return [] }
        var token: CKServerChangeToken?
        var memories: [UUID: VisitMemory] = [:]
        repeat {
            let page = try await database.recordZoneChanges(inZoneWith: zone, since: token)
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard record.recordType == "CrumbVisitMemory", record["pin"] as? String == pin.uuidString,
                      let uuid = UUID(uuidString: id.recordName),
                      let date = record["visitDate"] as? Date,
                      let source = (record["media"] as? CKAsset)?.fileURL else { continue }
                let memory = VisitMemory(id: uuid, date: date, video: record["isVideo"] as? Int == 1, shared: true)
                let destination = memory.file(pin)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: source).write(to: destination, options: .atomic)
                memories[uuid] = memory
            }
            for deletion in page.deletions {
                if let id = UUID(uuidString: deletion.recordID.recordName), let memory = memories.removeValue(forKey: id) {
                    try? FileManager.default.removeItem(at: memory.file(pin))
                }
            }
            token = page.moreComing ? page.changeToken : nil
        } while token != nil
        return Array(memories.values)
    }
}
