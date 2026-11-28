import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let view = UIHostingController(rootView: RecipeShareView(context: extensionContext))
        addChild(view); self.view.addSubview(view.view)
        view.view.frame = self.view.bounds
        view.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.didMove(toParent: self)
    }
}
private struct RecipeShareView: View {
    let context: NSExtensionContext?
    @State private var source: URL?
    @State private var done = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Import to crumb").font(.title.bold())
                if done {
                    Label("Link saved", systemImage: "checkmark.circle")
                    Text("Open crumb to review ingredients and directions before adding the recipe.")
                } else if let source {
                    Text(source.absoluteString).font(.subheadline)
                    Button("Save recipe link") {
                        do { try RecipeInbox.enqueue(source); done = true }
                        catch { self.error = "Could not save this link. Copy it and use Import link in crumb." }
                    }.buttonStyle(.borderedProminent).tint(Color(red: 38/255, green: 34/255, blue: 31/255))
                } else { Text("Looking for a recipe link…") }
                if let error { Text(error).font(.footnote) }
                Spacer()
            }.padding(24).background(.white)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { context?.completeRequest(returningItems: nil) } } }
                .task { await read() }
        }
    }
    @MainActor private func read() async {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                let item: NSSecureCoding? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in continuation.resume(returning: item) }
                }
                let raw = (item as? URL)?.absoluteString ?? (item as? String) ?? ""
                if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
                   let link = detector.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))?.url, link.scheme == "https" {
                    source = link; return
                }
            }
        }
        error = "No supported link was found. Copy the recipe URL and use Import link in crumb."
    }
}
