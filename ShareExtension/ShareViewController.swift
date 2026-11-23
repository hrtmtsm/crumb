import SwiftUI
import UniformTypeIdentifiers
import MapKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let controller = UIHostingController(rootView: InstagramShareForm(context: extensionContext))
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }
}

private struct InstagramShareForm: View {
    let context: NSExtensionContext?
    @State private var draft: InstagramDraft?
    @State private var ready = false
    @State private var saved = false
    @State private var failed = false
    @State private var query = ""
    @State private var destination = InstagramDraft.lastMap
    @State private var results: [MKMapItem] = []
    @State private var chosen: MKMapItem?
    @State private var searched = false
    @State private var searching = false

    private func enqueue(_ draft: InstagramDraft) {
        do { try draft.enqueue(); saved = true }
        catch { failed = true }
    }

    private func search() async {
        let term = query
        searching = true
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term
        request.resultTypes = .pointOfInterest
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard query == term else { return }
            results = Array(response.mapItems.prefix(12))
        } catch {
            guard query == term else { return }
            results = []
        }
        searched = true
    }

    var body: some View {
        NavigationStack {
            Form {
                if saved {
                    Label("共有を受け取りました", systemImage: "checkmark.circle")
                    Text(chosen == nil ? "crumbを開いて、お店と保存先を確認してください。" :
                            "保存を受け付けました。crumbを開くと地図に反映されます。")
                    Button("完了") { context?.completeRequest(returningItems: nil) }
                } else if let draft {
                    if let url = draft.url { InstagramPreview(url: url) { query = $0 } }
                    if !draft.text.isEmpty { Text(draft.text) }
                    Picker("保存先", selection: $destination) {
                        ForEach(InstagramDraft.destinations) { map in Text(map.title).tag(map.id) }
                    }
                    TextField("店名・エリア", text: $query)
                        .onChange(of: query) { chosen = nil; results = []; searched = false }
                    Button("店舗を検索") { Task { await search() } }
                        .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if searching { ProgressView() }
                    if searched && results.isEmpty { Text("候補がありません。下書きから手動で指定できます。") }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        Button {
                            chosen = item
                        } label: {
                            VStack(alignment: .leading) {
                                Label(item.name ?? "店舗", systemImage: chosen === item ? "checkmark.circle.fill" : "circle")
                                Text(item.placemark.title ?? "").font(.caption)
                            }
                        }
                    }
                    Button("ピンを保存") {
                        guard let chosen else { return }
                        var confirmed = draft
                        confirmed.confirmation = .init(name: chosen.name ?? query, address: chosen.placemark.title ?? "",
                                                       latitude: chosen.placemark.coordinate.latitude,
                                                       longitude: chosen.placemark.coordinate.longitude, mapID: destination)
                        enqueue(confirmed)
                    }
                    .disabled(chosen == nil || searching)
                    Button("下書きを残す") { enqueue(draft) }
                } else if ready {
                    Text("共有されたリンクやテキストを読み取れませんでした。")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("crumb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !saved {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { context?.cancelRequest(withError: CocoaError(.userCancelled)) }
                    }
                }
            }
        }
        .task {
            let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            var values = items.compactMap { $0.attributedContentText?.string }
            for provider in items.flatMap({ $0.attachments ?? [] }) {
                for type in [UTType.url, .plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                    if let value = try? await provider.loadItem(forTypeIdentifier: type.identifier) {
                        if let url = value as? URL { values.append(url.absoluteString) }
                        if let text = value as? String { values.append(text) }
                    }
                }
            }
            var seen = Set<String>()
            let item = InstagramDraft(items: values.filter { seen.insert($0).inserted })
            if item.url != nil || !item.text.isEmpty {
                draft = item
                query = item.text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(80)) } ?? ""
            }
            if !InstagramDraft.destinations.contains(where: { $0.id == destination }) { destination = "mine" }
            ready = true
        }
        .alert("下書きを保存できませんでした", isPresented: $failed) {
            Button("閉じる", role: .cancel) {}
        }
    }
}
